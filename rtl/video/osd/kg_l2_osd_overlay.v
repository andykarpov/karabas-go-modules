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
   over the video by osd_alpha (0 none .. 3 three quarters); a shadow of 4 OSD pixels to the
   right and below darkens the video.
 - Latency: 2 clocks; hs_o / vs_o / de_o come with rgb_o. The settings are taken at the start
   of a frame (the multi-bit values cross from the link clock while they are stable).
*/

module kg_l2_osd_overlay #(
	parameter SCALE = 0   // 0 = from the size of the area
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
wire [12:0] W2 = ww_n * { s_auto, 1'b0 };
wire [12:0] H2 = wh_n * { s_auto, 1'b0 };
wire zoom_fits = popup_now && zoom_v && W2 <= { 1'b0, aw } && H2 <= { 1'b0, ah };
wire [3:0] s_n = zoom_fits ? { s_auto[2:0], 1'b0 } : s_auto;
wire [12:0] W_n = ww_n * s_n;
wire [12:0] H_n = wh_n * s_n;
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

// ---------------- the OSD pixel of the screen pixel ----------------

wire signed [13:0] xs = $signed({ 2'b00, x });
wire signed [13:0] ys = $signed({ 2'b00, y });
wire signed [13:0] Ws = $signed({ 1'b0, W });
wire signed [13:0] Hs = $signed({ 1'b0, H });
wire signed [13:0] b = $signed({ 9'd0, s, 1'b0 });   // the border: 2 OSD pixels
wire signed [13:0] sh = $signed({ 8'd0, s, 2'b00 }); // the shadow: 4

wire in_x = xs >= x0 && xs < x0 + Ws;
wire in_y = ys >= y0 && ys < y0 + Hs;
wire bd_x = xs >= x0 - b && xs < x0 + Ws + b;
wire bd_y = ys >= y0 - b && ys < y0 + Hs + b;
wire sh_x = xs >= x0 - b + sh && xs < x0 + Ws + b + sh;
wire sh_y = ys >= y0 - b + sh && ys < y0 + Hs + b + sh;

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

// the background over the video, per channel
/* verilator lint_off UNUSEDSIGNAL */
function [7:0] blend(input [7:0] o, input [7:0] v, input [1:0] a);
	reg [9:0] t; // the low 2 bits drop: a sum of 4 weights
	begin
		case (a)
			2'd0: t = { 2'b00, v };
			2'd1: t = { 2'b00, o } + { 1'b0, v, 1'b0 } + { 2'b00, v };      // o + 3v
			2'd2: t = { 1'b0, o, 1'b0 } + { 1'b0, v, 1'b0 };                 // 2o + 2v
			default: t = { 1'b0, o, 1'b0 } + { 2'b00, o } + { 2'b00, v };    // 3o + v
		endcase
		blend = (a == 2'd0) ? v : t[9:2];
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
	else if (k_shadow)
		rgb_o <= { 1'b0, rgb1[23:17], 1'b0, rgb1[15:9], 1'b0, rgb1[7:1] };
	else
		rgb_o <= rgb1;
end

endmodule
