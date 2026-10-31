`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_osd_overlay.v

 OSD of the mcu over the video of the core, the Verilog port of overlay.vhd (karabas-go-core-
 nanomig): 32 x 26 characters of an 8 x 8 font, both loaded by the mcu through osd_command
 (CMD_OSD of mcu.vhd, karabas-go-firmware docs/protocol.md):
   01 n   overlay on / off (bit 0)       10 x   cursor column (0-31)
   02 n   popup on / off (bit 0)         11 y   cursor row
   12 c   character                      13 a   attribute: writes character and attribute
   20 1   font address to the start      21 d   next font byte
 A command is taken when osd_command changes. Attribute: bits 7-5 ink GRB-ordered RGB, 4 bright
 ink, 3-1 paper, 0 bright paper; ink = paper = 0001 flashes.

 The position follows the syncs: the counters start at the leading edge of hsync / vsync (high
 active), their length picks the scale (lines under 500 clocks: a counter step per clock, under
 H_DIV4_WIDTH: per 2, else per 4; frames under 400 / 800 lines likewise), H_OFFSET / V_OFFSET
 are in those steps. Popup: the characters twice as large. With the OSD on, the video under it is
 dimmed to 5 bits per colour. ALWAYS_ON: the OSD is on also with overlay and popup off (the boot
 menu, whose screen is the OSD; its DEFAULT). V_OFFSET_IN: the vertical offset is the input
 v_offset instead of V_OFFSET (baseconf: 34 lines at 60 Hz, 64 at 50 Hz); with 0 the input is
 not used and may stay unconnected.

 overlay.vhd read the character and its font line in a process without a clock (latches); here
 the addresses are combinational (the block RAMs read every clock, the cell address stays during
 the cell) and attribute / font line are registers: the same values reach the shifter in the
 same clock. One difference: when popup or overlay is switched, overlay.vhd kept the addresses
 of the mode before until its next read phase, here the next cell is read in the new mode (one
 or two cells of that frame differ). Everything else as overlay.vhd, also its quirks.
*/

module kg_osd_overlay #(
	parameter H_OFFSET = 120, // tsconf: 120 / 72
	parameter V_OFFSET = 72,
	parameter H_DIV4_WIDTH = 1000, // lines of this many clocks or more: a step per 4 (menu: 1200, 800 x 600)
	parameter ALWAYS_ON = 0,
	parameter V_OFFSET_IN = 0
) (
	input wire clk,
	input wire [23:0] rgb_i,
	output wire [23:0] rgb_o,
	input wire hsync_i,
	input wire vsync_i,
	input wire [10:0] v_offset, // V_OFFSET_IN only
	input wire [15:0] osd_command
);

localparam PAPER_CHARS_H = 32;
localparam PAPER_CHARS_V = 26;
localparam PAPER_END_H = PAPER_CHARS_H * 8;
localparam PAPER_END_V = PAPER_CHARS_V * 8;

// ---------------- line and frame counters ----------------

reg prev_hsync = 1'b0, prev_vsync = 1'b0;
reg [10:0] hcnt_i = 11'd0, vcnt_i = 11'd0, width = 11'd0, height = 11'd0;
reg [7:0] flash_cnt = 8'd0;

always @(posedge clk) begin
	prev_hsync <= hsync_i;
	if (hsync_i && !prev_hsync) begin // a new line
		width <= hcnt_i;
		hcnt_i <= 11'd0;
		vcnt_i <= vcnt_i + 11'd1;
		prev_vsync <= vsync_i;
		if (vsync_i && !prev_vsync) begin // a new frame
			height <= vcnt_i;
			vcnt_i <= 11'd0;
			flash_cnt <= flash_cnt + 8'd1;
		end
	end
	else
		hcnt_i <= hcnt_i + 11'd1;
end

wire [10:0] hcnt = ((width < 500) ? hcnt_i : (width < H_DIV4_WIDTH) ? { 1'b0, hcnt_i[10:1] } : { 2'b00, hcnt_i[10:2] }) - H_OFFSET;
wire [10:0] vcnt = ((height < 400) ? vcnt_i : (height < 800) ? { 1'b0, vcnt_i[10:1] } : { 2'b00, vcnt_i[10:2] }) - (V_OFFSET_IN ? v_offset : V_OFFSET);

// ---------------- commands ----------------

reg [15:0] last_command = 16'd0;
reg osd_overlay = 1'b0, osd_popup = 1'b0;
reg [9:0] addr_write = 10'd0;
reg [7:0] char_buf = 8'd0;
reg [15:0] vram_di = 16'd0;
reg vram_wr = 1'b0;
reg [10:0] font_addr = 11'h7FF;
reg [7:0] font_data = 8'd0;
reg font_upd = 1'b0, font_prev_upd = 1'b0, font_we = 1'b0;

always @(posedge clk) begin
	vram_wr <= 1'b0;
	if (osd_command != last_command) begin
		last_command <= osd_command;
		case (osd_command[15:8])
			8'h01: osd_overlay <= osd_command[0];
			8'h02: osd_popup <= osd_command[0];
			8'h10: addr_write[4:0] <= osd_command[4:0];
			8'h11: addr_write[9:5] <= osd_command[4:0];
			8'h12: char_buf <= osd_command[7:0];
			8'h13: begin
				vram_wr <= 1'b1;
				vram_di <= { char_buf, osd_command[7:0] };
			end
			8'h20:
				if (osd_command[0]) begin // font address to the start
					font_addr <= 11'h7FF;
					font_upd <= 1'b0;
					font_prev_upd <= 1'b0;
				end
			8'h21: begin // next font byte
				font_addr <= font_addr + 11'd1;
				font_data <= osd_command[7:0];
				font_upd <= ~font_upd;
			end
			default: ;
		endcase
	end

	// the font write, a clock after its command
	font_we <= 1'b0;
	if (font_prev_upd != font_upd) begin
		font_prev_upd <= font_upd;
		font_we <= 1'b1;
	end
end

// ---------------- font and character memories ----------------

wire [15:0] vram_do;
wire [7:0] font_word;
wire [9:0] addr_read = osd_popup ? { vcnt[8:4], hcnt[8:4] } : { vcnt[7:3], hcnt[7:3] };
wire [10:0] rom_addr = { vram_do[15:8], osd_popup ? vcnt[3:1] : vcnt[2:0] };

kg_sdpram #(.DW(8), .AW(11)) u_font(
	.clka(clk), .wea(font_we), .addra(font_addr), .dina(font_data),
	.clkb(clk), .enb(1'b1), .addrb(rom_addr), .doutb(font_word)
);

kg_sdpram #(.DW(16), .AW(10)) u_vram(
	.clka(clk), .wea(vram_wr), .addra(addr_write), .dina(vram_di),
	.clkb(clk), .enb(1'b1), .addrb(addr_read), .doutb(vram_do)
);

// ---------------- character cells ----------------

// paper2: the cells read; paper: the cells shown, a cell later
wire paper2 = hcnt < PAPER_END_H && vcnt < PAPER_END_V;
wire paper = hcnt >= 8 && hcnt < PAPER_END_H + 8 && vcnt < PAPER_END_V;
wire video_on = osd_overlay | osd_popup | (ALWAYS_ON != 0);

// phase in a cell: popup 16 counter steps, else 8
wire [3:0] phase = osd_popup ? hcnt[3:0] : { 1'b0, hcnt[2:0] };
wire ph_attr = osd_popup ? phase == 4'd10 : phase == 4'd5;   // vram_do has the cell
wire ph_font = osd_popup ? phase == 4'd11 : phase == 4'd6;   // font_word has its line
wire ph_load = osd_popup ? phase == 4'd15 : phase == 4'd7;   // to the shifter

reg [7:0] attr2 = 8'd0, bitmap2 = 8'd0, attr = 8'd0, bitmap = 8'd0;
reg load_dbl = 1'b0, shift_dbl = 1'b0;

always @(posedge clk) begin
	if (paper2 && ph_attr)
		attr2 <= vram_do[7:0];
	if (paper2 && ph_font)
		bitmap2 <= font_word;
	if (paper2 && ph_load) begin
		attr <= attr2;
		bitmap <= bitmap2;
	end
	load_dbl <= paper2 && ph_load;
	shift_dbl <= paper && !ph_load;
end

wire pixel;
kg_pix_doubler u_dbl(
	.clk(clk), .load(load_dbl), .shift(shift_dbl), .d(bitmap), .quad({ 1'b1, osd_popup }), .dout(pixel)
);

// ---------------- output ----------------

wire flash = flash_cnt[5];
wire is_flash = attr[3:0] == 4'b0001;
wire [3:0] selector = { video_on, pixel, flash, is_flash };

wire [23:0] rgb_fg = {
	attr[7] & attr[4], attr[7], attr[7], 5'b00000,
	attr[6] & attr[4], attr[6], attr[6], 5'b00000,
	attr[5] & attr[4], attr[5], attr[5], 5'b00000 };
wire [23:0] rgb_bg = {
	attr[3] & attr[0], attr[3], attr[3], 5'b00000,
	attr[2] & attr[0], attr[2], attr[2], 5'b00000,
	attr[1] & attr[0], attr[1], attr[1], 5'b00000 };

wire show_fg = rgb_fg != 24'd0 && paper &&
	(selector == 4'b1111 || selector == 4'b1001 || selector == 4'b1100 || selector == 4'b1110);
wire show_bg = rgb_bg != 24'd0 && paper &&
	(selector == 4'b1011 || selector == 4'b1101 || selector == 4'b1000 || selector == 4'b1010);

assign rgb_o = show_fg ? rgb_fg : show_bg ? rgb_bg :
	video_on ? { 3'b000, rgb_i[23:19], 3'b000, rgb_i[15:11], 3'b000, rgb_i[7:3] } : rgb_i;

endmodule
