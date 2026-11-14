`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_osd_overlay.v

 The bitmap OSD of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.3) over the video of the
 core: 256 x 128 monochrome in the u8g2 page layout, written by kg_l2_osd (osd_* of kg_mcu2,
 in the clock of the link) and drawn here in the video clock.

 - The active area is measured from de every frame (its width in clocks, its height in lines;
   a frame starts at the rising edge of vs, hs / vs / de high active). The scale is the largest
   integer of 1 (under 512 x 256), 2, 3 (from 1024 x 512), 4 (from 1280 x 640), or SCALE.
 - The OSD is centred; a popup window (osd_pw != 0) shows only its part of the bitmap, at the
   centre, the top or the bottom of the area, with zoom twice as large when that fits.
 - Text pixels are osd_fg, the rest of the OSD and a border of 2 OSD pixels are osd_bg blended
   over the video by osd_alpha (0 none, 1 a half, 2 three quarters, 3 opaque); a shadow of 4 OSD pixels to the
   right and below darkens the video.
 - Activity icons (ICONS_N of them, 0..8): a row (or with ICON_COLUMN a column) of 16 x 16
   pictures in a corner of the area (ICON_CORNER), at the scale of the OSD (or ICON_SCALE), under
   it, ICON_MARGIN screen pixels from the edges (0: 8 icon pixels). Icon n has the picture ICON_SET[n*4 +: 4]
   (0 floppy, 1 SD card, 2 CF card, 3 hard disk, 4 tape), is shown dim (ICON_DIM) while
   icon_on[n] (mounted) and bright (ICON_COLOR) while it is active, on a darkened box (ICON_BOX 1)
   or with the video around its pixels (ICON_BOX 0): icon_act[n] (wclk, a pulse is enough) is
   held 2^STRETCH_BITS clocks of wclk and then ICON_HOLD frames.
 - Latency: 2 clocks; hs_o / vs_o / de_o come with rgb_o. The settings are taken at the start
   of a frame (the multi-bit values cross from the link clock while they are stable).
*/

module kg_l2_osd_overlay #(
	parameter SCALE = 0,                    // 0 = from the size of the area
	parameter ICONS_N = 0,                  // the activity icons (0..8)
	parameter [31:0] ICON_SET = 32'h76543210, // the picture of icon n in bits n*4 +: 4
	parameter ICON_CORNER = 0,              // 0 top right, 1 top left, 2 bottom right, 3 bottom left
	parameter ICON_COLUMN = 0,              // 0 a row of icons, 1 a column
	parameter ICON_SCALE = 0,               // screen pixels per icon pixel; 0 = the scale of the OSD
	parameter ICON_MARGIN = 0,              // screen pixels from the edges; 0 = 8 icon pixels
	parameter ICON_BOX = 1,                 // 1 a dark box behind an icon shown, 0 none
	parameter [23:0] ICON_COLOR = 24'h40FF40, // an active icon
	parameter [23:0] ICON_DIM = 24'h909090,   // a mounted one
	parameter STRETCH_BITS = 18,            // activity held 2^n clocks of wclk (2^18 at 28 MHz: 9 ms)
	parameter ICON_HOLD = 6                 // then this many frames
) (
	// the link side (kg_mcu2 OSD_*)
	input wire wclk,
	input wire osd_wr,
	input wire [11:0] osd_waddr,
	input wire [7:0] osd_wdata,
	input wire osd_en,
	input wire [23:0] osd_fg,
	input wire [23:0] osd_bg,
	input wire [1:0] osd_alpha,
	input wire [4:0] osd_px,
	input wire [3:0] osd_py,
	input wire [5:0] osd_pw,
	input wire [4:0] osd_ph,
	input wire [1:0] osd_place,
	input wire osd_zoom,
	/* verilator lint_off UNUSEDSIGNAL */ // the icons past ICONS_N
	input wire [7:0] icon_on,     // wclk: the icon is shown (dim)
	input wire [7:0] icon_act,    // wclk: activity (bright)
	/* verilator lint_on UNUSEDSIGNAL */

	// the video
	input wire clk,
	input wire [23:0] rgb_i,
	input wire hs_i,
	input wire vs_i,
	input wire de_i,
	output reg [23:0] rgb_o = 24'd0,
	output reg hs_o = 1'b0,
	output reg vs_o = 1'b0,
	output reg de_o = 1'b0
);

// ---------------- the bitmap ----------------

wire [11:0] raddr;
wire [7:0] rbyte;
kg_sdpram #(.DW(8), .AW(12)) u_bitmap(
	.clka(wclk), .wea(osd_wr), .addra(osd_waddr), .dina(osd_wdata),
	.clkb(clk), .enb(1'b1), .addrb(raddr), .doutb(rbyte)
);

// ---------------- the settings, into the video clock ----------------

// two registers in this clock; they change seldom and are used at the start of a frame
localparam CW = 1 + 24 + 24 + 2 + 5 + 4 + 6 + 5 + 2 + 1;
wire [CW-1:0] ctl_w = { osd_en, osd_fg, osd_bg, osd_alpha, osd_px, osd_py, osd_pw, osd_ph, osd_place, osd_zoom };
reg [CW-1:0] ctl_1 = {CW{1'b0}}, ctl = {CW{1'b0}};
always @(posedge clk) begin
	ctl_1 <= ctl_w;
	ctl <= ctl_1;
end
wire en_v = ctl[CW-1];
wire [23:0] fg_v = ctl[CW-2 -: 24];
wire [23:0] bg_v = ctl[CW-26 -: 24];
wire [1:0] alpha_v = ctl[CW-50 -: 2];
wire [4:0] px_v = ctl[CW-52 -: 5];
wire [3:0] py_v = ctl[CW-57 -: 4];
wire [5:0] pw_v = ctl[CW-61 -: 6];
wire [4:0] ph_v = ctl[CW-67 -: 5];
wire [1:0] place_v = ctl[CW-72 -: 2];
wire zoom_v = ctl[0];
wire popup_now = pw_v != 6'd0;
wire vis_now = en_v || popup_now;

// ---------------- the area ----------------

reg de_d = 1'b0, vs_d = 1'b0;
always @(posedge clk) begin
	de_d <= de_i;
	vs_d <= vs_i;
end
wire line_start = de_i && !de_d;
wire line_end = !de_i && de_d;
wire frame_start = vs_i && !vs_d;

reg [11:0] x = 12'd0;     // the pixel in the line (from the start of de)
reg [11:0] y = 12'd0;     // the line in the frame (lines with de)
reg [11:0] aw = 12'd0, ah = 12'd0;
always @(posedge clk) begin
	if (line_start)
		x <= 12'd0;
	else if (de_i)
		x <= x + 1'b1;
	if (line_end)
		aw <= x;
	if (frame_start) begin
		ah <= y;
		y <= 12'd0;
	end
	else if (line_end)
		y <= y + 1'b1;
end

// the geometry of the frame, set at its start
reg vis = 1'b0;
reg [3:0] s = 4'd2;                       // screen pixels per OSD pixel
reg [7:0] wx0 = 8'd0;                     // its first column / line in the bitmap
reg [6:0] wy0 = 7'd0;
reg signed [13:0] x0 = 14'sd0, y0 = 14'sd0; // its first screen pixel / line
reg [12:0] W = 13'd0, H = 13'd0;          // its size on the screen
reg [23:0] fg = 24'hFFFFFF, bg = 24'd0;
reg [1:0] alpha = 2'd2;

wire [3:0] s_auto = (SCALE != 0) ? SCALE[3:0] :
	(aw >= 12'd1280 && ah >= 12'd640) ? 4'd4 :
	(aw >= 12'd1024 && ah >= 12'd512) ? 4'd3 :
	(aw >= 12'd512 && ah >= 12'd256) ? 4'd2 : 4'd1;
wire [8:0] ww_n = popup_now ? { pw_v, 3'b000 } : 9'd256;
wire [8:0] wh_n = popup_now ? { 1'b0, ph_v, 3'b000 } : 9'd128;
wire [12:0] W1 = ww_n * s_auto;
wire [12:0] H1 = wh_n * s_auto;
wire [12:0] W2 = { W1[11:0], 1'b0 };
wire [12:0] H2 = { H1[11:0], 1'b0 };
wire zoom_fits = popup_now && zoom_v && W2 <= { 1'b0, aw } && H2 <= { 1'b0, ah };
wire [3:0] s_n = zoom_fits ? { s_auto[2:0], 1'b0 } : s_auto;
wire [12:0] W_n = zoom_fits ? W2 : W1;
wire [12:0] H_n = zoom_fits ? H2 : H1;
wire signed [13:0] margin = $signed({ 7'd0, s_n, 3'b000 }); // 8 OSD pixels from the top / bottom

always @(posedge clk)
	if (frame_start) begin
		vis <= vis_now;
		s <= s_n;
		wx0 <= popup_now ? { px_v, 3'b000 } : 8'd0;
		wy0 <= popup_now ? { py_v, 3'b000 } : 7'd0;
		W <= W_n;
		H <= H_n;
		x0 <= ($signed({ 2'b00, aw }) - $signed({ 1'b0, W_n })) >>> 1;
		y0 <= (!popup_now || place_v == 2'd0) ? ($signed({ 2'b00, ah }) - $signed({ 1'b0, H_n })) >>> 1 :
		      (place_v == 2'd1) ? margin :
		      $signed({ 2'b00, ah }) - $signed({ 1'b0, H_n }) - margin;
		fg <= fg_v;
		bg <= bg_v;
		alpha <= alpha_v;
	end

// the far edges of the border and of the shadow, a clock after the start of the frame
reg frame_start_d = 1'b0;
reg signed [13:0] Wb = 14'sd0, W3 = 14'sd0, Hb = 14'sd0, H3 = 14'sd0;
always @(posedge clk) begin
	frame_start_d <= frame_start;
	if (frame_start_d) begin
		Wb <= $signed({ 1'b0, W }) + $signed({ 9'd0, s, 1'b0 });
		W3 <= $signed({ 1'b0, W }) + $signed({ 9'd0, s, 1'b0 }) + $signed({ 8'd0, s, 2'b00 });
		Hb <= $signed({ 1'b0, H }) + $signed({ 9'd0, s, 1'b0 });
		H3 <= $signed({ 1'b0, H }) + $signed({ 9'd0, s, 1'b0 }) + $signed({ 8'd0, s, 2'b00 });
	end
end

// ---------------- the OSD pixel of the screen pixel ----------------

wire signed [13:0] xs = $signed({ 2'b00, x });
wire signed [13:0] ys = $signed({ 2'b00, y });
wire signed [13:0] Ws = $signed({ 1'b0, W });
wire signed [13:0] Hs = $signed({ 1'b0, H });
wire signed [13:0] b = $signed({ 9'd0, s, 1'b0 });   // the border: 2 OSD pixels (the shadow: 4 more)

// the pixel from the corner of the window: one subtractor per axis, the edges are constants of
// the frame (the border from -b to W + b, the shadow from b to W + 3b)
wire signed [13:0] ux = xs - x0;
wire signed [13:0] uy = ys - y0;
wire in_x = !ux[13] && ux < Ws;
wire in_y = !uy[13] && uy < Hs;
wire bd_x = ux >= -b && ux < Wb;
wire bd_y = uy >= -b && uy < Hb;
wire sh_x = ux >= b && ux < W3;
wire sh_y = uy >= b && uy < H3;

// the column / line of the bitmap: counters that step once per s screen pixels / lines
reg [3:0] hsub = 4'd0, vsub = 4'd0;
reg [8:0] ox = 9'd0;
reg [7:0] oy = 8'd0;
always @(posedge clk) begin
	if (line_start) begin
		hsub <= 4'd0;
		ox <= 9'd0;
	end
	else if (de_i && in_x) begin
		if (hsub == s - 1'b1) begin
			hsub <= 4'd0;
			ox <= ox + 1'b1;
		end
		else
			hsub <= hsub + 1'b1;
	end
	if (frame_start) begin
		vsub <= 4'd0;
		oy <= 8'd0;
	end
	else if (line_end && in_y) begin
		if (vsub == s - 1'b1) begin
			vsub <= 4'd0;
			oy <= oy + 1'b1;
		end
		else
			vsub <= vsub + 1'b1;
	end
end

wire [7:0] col = wx0 + ox[7:0];
wire [6:0] lin = wy0 + oy[6:0];
// the byte of this pixel is read in this clock (the block RAM registers it), its kind and the
// video go along by a register: both reach stage 2 together
assign raddr = { lin[6:3], col };

// stage 1: the byte of the bitmap is read, the kind of the pixel goes along
reg [2:0] bitn = 3'd0;
reg k_text = 1'b0, k_border = 1'b0, k_shadow = 1'b0;
reg [23:0] rgb1 = 24'd0;
reg hs1 = 1'b0, vs1 = 1'b0, de1 = 1'b0;
always @(posedge clk) begin
	bitn <= lin[2:0];
	k_text <= vis && de_i && in_x && in_y;
	k_border <= vis && de_i && bd_x && bd_y;
	k_shadow <= vis && de_i && sh_x && sh_y;
	rgb1 <= rgb_i;
	hs1 <= hs_i;
	vs1 <= vs_i;
	de1 <= de_i;
end

// ---------------- the activity icons ----------------

// the pictures: row y of icon i at i * 16 + y (bit 15 = the left pixel): 0 floppy, 1 SD, 2 CF,
// 3 hard disk, 4 tape; a ROM read a clock before its pixel
reg [15:0] icon_rom [0:127];
integer ri;
initial begin
	for (ri = 0; ri < 128; ri = ri + 1) icon_rom[ri] = 16'h0000;
	icon_rom[0] = 16'h0000;
	icon_rom[1] = 16'hFFF8;
	icon_rom[2] = 16'hF01C;
	icon_rom[3] = 16'hF05E;
	icon_rom[4] = 16'hF05E;
	icon_rom[5] = 16'hF01E;
	icon_rom[6] = 16'hFFFE;
	icon_rom[7] = 16'hFFFE;
	icon_rom[8] = 16'hFFFE;
	icon_rom[9] = 16'hFFFE;
	icon_rom[10] = 16'hE00E;
	icon_rom[11] = 16'hEFEE;
	icon_rom[12] = 16'hE00E;
	icon_rom[13] = 16'hEFEE;
	icon_rom[14] = 16'hE00E;
	icon_rom[15] = 16'hFFFE;
	icon_rom[16] = 16'h0000;
	icon_rom[17] = 16'h1FFE;
	icon_rom[18] = 16'h3926;
	icon_rom[19] = 16'h6926;
	icon_rom[20] = 16'hC926;
	icon_rom[21] = 16'hCFFE;
	icon_rom[22] = 16'hFFFE;
	icon_rom[23] = 16'hC10E;
	icon_rom[24] = 16'hCF36;
	icon_rom[25] = 16'hC136;
	icon_rom[26] = 16'hF936;
	icon_rom[27] = 16'hC10E;
	icon_rom[28] = 16'hFFFE;
	icon_rom[29] = 16'hC006;
	icon_rom[30] = 16'hFFFE;
	icon_rom[31] = 16'hFFFE;
	icon_rom[32] = 16'h0000;
	icon_rom[33] = 16'h7FFC;
	icon_rom[34] = 16'hFFFE;
	icon_rom[35] = 16'hC106;
	icon_rom[36] = 16'hCF3E;
	icon_rom[37] = 16'hCF0E;
	icon_rom[38] = 16'hCF3E;
	icon_rom[39] = 16'hC13E;
	icon_rom[40] = 16'hFFFE;
	icon_rom[41] = 16'hC006;
	icon_rom[42] = 16'hFFFE;
	icon_rom[43] = 16'hD556;
	icon_rom[44] = 16'hFFFE;
	icon_rom[45] = 16'hD556;
	icon_rom[46] = 16'hFFFE;
	icon_rom[47] = 16'h7FFC;
	icon_rom[48] = 16'h0000;
	icon_rom[49] = 16'h3FFC;
	icon_rom[50] = 16'h4002;
	icon_rom[51] = 16'h4FF2;
	icon_rom[52] = 16'h500A;
	icon_rom[53] = 16'h518A;
	icon_rom[54] = 16'h524A;
	icon_rom[55] = 16'h518A;
	icon_rom[56] = 16'h502A;
	icon_rom[57] = 16'h4F92;
	icon_rom[58] = 16'h4012;
	icon_rom[59] = 16'h4002;
	icon_rom[60] = 16'h583A;
	icon_rom[61] = 16'h4002;
	icon_rom[62] = 16'h3FFC;
	icon_rom[63] = 16'h0000;
	icon_rom[64] = 16'h0000;
	icon_rom[65] = 16'h0000;
	icon_rom[66] = 16'h7FFE;
	icon_rom[67] = 16'h4002;
	icon_rom[68] = 16'h5FFA;
	icon_rom[69] = 16'h524A;
	icon_rom[70] = 16'h55AA;
	icon_rom[71] = 16'h524A;
	icon_rom[72] = 16'h5FFA;
	icon_rom[73] = 16'h4002;
	icon_rom[74] = 16'h47E2;
	icon_rom[75] = 16'h4812;
	icon_rom[76] = 16'h7FFE;
	icon_rom[77] = 16'h0000;
	icon_rom[78] = 16'h0000;
	icon_rom[79] = 16'h0000;
end

// activity in wclk: a pulse held 2^STRETCH_BITS clocks
reg [7:0] act_lvl = 8'd0;
genvar gi;
generate
	for (gi = 0; gi < ICONS_N; gi = gi + 1) begin : kg_l2_icon_act
		reg [STRETCH_BITS-1:0] cnt = {STRETCH_BITS{1'b0}};
		always @(posedge wclk) begin
			if (icon_act[gi])
				cnt <= {STRETCH_BITS{1'b1}};
			else if (cnt != 0)
				cnt <= cnt - 1'b1;
			act_lvl[gi] <= cnt != 0 || icon_act[gi];
		end
	end
endgenerate

// into the video clock, then held ICON_HOLD frames
reg [7:0] on_s1 = 8'd0, on_s = 8'd0, act_s1 = 8'd0, act_s = 8'd0;
reg [7:0] lit = 8'd0;
reg [2:0] hold [0:7];
integer hi;
initial for (hi = 0; hi < 8; hi = hi + 1) hold[hi] = 3'd0;
always @(posedge clk) begin
	on_s1 <= icon_on;
	on_s <= on_s1;
	act_s1 <= act_lvl;
	act_s <= act_s1;
	for (hi = 0; hi < 8; hi = hi + 1) begin
		if (act_s[hi])
			hold[hi] <= ICON_HOLD[2:0];
		else if (frame_start && hold[hi] != 3'd0)
			hold[hi] <= hold[hi] - 3'd1;
		lit[hi] <= act_s[hi] || hold[hi] != 3'd0;
	end
end

// the row (column) of icons: slots of 16 + 4 icon pixels, ICON_MARGIN from the edges of the area
localparam IW = (ICONS_N > 0) ? ICONS_N * 20 - 4 : 0;
reg [3:0] si = 4'd2;
reg signed [13:0] ix0 = 14'sd0, iy0 = 14'sd0;
reg [12:0] iW = 13'd0, iH = 13'd0;
wire [3:0] s_ic = (ICON_SCALE != 0) ? ICON_SCALE[3:0] : s_auto;
localparam [12:0] IWC = (ICON_COLUMN != 0) ? 13'd16 : IW[12:0]; // icon pixels across / down
localparam [12:0] IHC = (ICON_COLUMN != 0) ? IW[12:0] : 13'd16;
localparam [13:0] IMC = ICON_MARGIN[13:0];
wire [12:0] iW_n = IWC * s_ic;
wire [12:0] iH_n = IHC * s_ic;
wire signed [13:0] im = (ICON_MARGIN != 0) ? $signed(IMC) : $signed({ 7'd0, s_ic, 3'b000 });
always @(posedge clk)
	if (frame_start) begin
		si <= s_ic;
		iW <= iW_n;
		iH <= iH_n;
		ix0 <= (ICON_CORNER == 1 || ICON_CORNER == 3) ? im : $signed({ 2'b00, aw }) - $signed({ 1'b0, iW_n }) - im;
		iy0 <= (ICON_CORNER < 2) ? im : $signed({ 2'b00, ah }) - $signed({ 1'b0, iH_n }) - im;
	end

wire signed [13:0] iu = xs - ix0;
wire signed [13:0] iv = ys - iy0;
wire ic_x = !iu[13] && iu < $signed({ 1'b0, iW });
wire ic_y = !iv[13] && iv < $signed({ 1'b0, iH });
reg [3:0] ihsub = 4'd0, ivsub = 4'd0;
reg [4:0] ipx = 5'd0;     // the pixel in the slot (0..19; in a column 0..15)
reg [2:0] islot = 3'd0;   // the slot in a row
reg [4:0] ipy = 5'd0;     // the line in the slot (0..15; in a column 0..19)
reg [2:0] vslot = 3'd0;   // the slot in a column
always @(posedge clk) begin
	if (line_start) begin
		ihsub <= 4'd0;
		ipx <= 5'd0;
		islot <= 3'd0;
	end
	else if (de_i && ic_x) begin
		if (ihsub == si - 1'b1) begin
			ihsub <= 4'd0;
			if (ICON_COLUMN == 0 && ipx == 5'd19) begin
				ipx <= 5'd0;
				islot <= islot + 1'b1;
			end
			else
				ipx <= ipx + 1'b1;
		end
		else
			ihsub <= ihsub + 1'b1;
	end
	if (frame_start) begin
		ivsub <= 4'd0;
		ipy <= 5'd0;
		vslot <= 3'd0;
	end
	else if (line_end && ic_y) begin
		if (ivsub == si - 1'b1) begin
			ivsub <= 4'd0;
			if (ICON_COLUMN != 0 && ipy == 5'd19) begin
				ipy <= 5'd0;
				vslot <= vslot + 1'b1;
			end
			else
				ipy <= ipy + 1'b1;
		end
		else
			ivsub <= ivsub + 1'b1;
	end
end

wire [2:0] slot = (ICON_COLUMN != 0) ? vslot : islot;
wire [2:0] ic_id = ICON_SET[{ slot, 2'b00 } +: 3]; // pictures 0..7
reg [15:0] ic_row = 16'd0;       // the row of the pixel of stage 1, in stage 2
always @(posedge clk)
	ic_row <= icon_rom[{ ic_id, ipy[3:0] }];
wire ic_in = (ICONS_N > 0) && de_i && ic_x && ic_y && ipx < 5'd16 && ipy < 5'd16 && { 1'b0, slot } < ICONS_N[3:0] &&
             (on_s[slot] || lit[slot]);

reg k_ibox = 1'b0, k_ilit = 1'b0;
reg [3:0] k_ipx = 4'd0;
always @(posedge clk) begin
	k_ibox <= ic_in;
	k_ipx <= ipx[3:0];
	k_ilit <= lit[slot];
end
wire k_ipix = k_ibox && ic_row[4'd15 - k_ipx];

// the background over the video, per channel
/* verilator lint_off UNUSEDSIGNAL */
function [7:0] blend(input [7:0] o, input [7:0] v, input [1:0] a);
	reg [9:0] t; // the low 2 bits drop: a sum of 4 weights
	begin
		// 2o + v, then + v (a = 1: 2o + 2v) or + o (3o + v)
		t = { 1'b0, o, 1'b0 } + { 2'b00, v } + { 2'b00, (a == 2'd1) ? v : o };
		blend = (a == 2'd0) ? v : (a == 2'd3) ? o : t[9:2];
	end
endfunction
/* verilator lint_on UNUSEDSIGNAL */

// stage 2: the pixel
always @(posedge clk) begin
	hs_o <= hs1;
	vs_o <= vs1;
	de_o <= de1;
	if (k_text && rbyte[bitn])
		rgb_o <= fg;
	else if (k_border)
		rgb_o <= { blend(bg[23:16], rgb1[23:16], alpha), blend(bg[15:8], rgb1[15:8], alpha), blend(bg[7:0], rgb1[7:0], alpha) };
	else if (k_ipix)
		rgb_o <= k_ilit ? ICON_COLOR : ICON_DIM;
	else if (ICON_BOX != 0 && k_ibox)
		rgb_o <= { 2'b00, rgb1[23:18], 2'b00, rgb1[15:10], 2'b00, rgb1[7:2] }; // a dark box
	else if (k_shadow)
		rgb_o <= { 1'b0, rgb1[23:17], 1'b0, rgb1[15:9], 1'b0, rgb1[7:1] };
	else
		rgb_o <= rgb1;
end

endmodule
