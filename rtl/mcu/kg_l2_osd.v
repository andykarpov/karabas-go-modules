`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_osd.v

 Target 02 OSD of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.3), on the byte bus of
 kg_l2_link: the commands of the bitmap OSD. The bitmap and the drawing are kg_l2_osd_overlay,
 in the video clock of the core; this side gives it the writes and the settings (osd_*).

   01 ENABLE  bit 0 show
   02 WRITE   tile (2 bytes, LE), data bytes: the bitmap from byte tile x 8 on (wrapping at 4 KB);
              osd_wr one clock per byte with osd_waddr / osd_wdata
   03 COLORS  fg R G B, bg R G B, bg alpha (0..3)
   04 POPUP   x, y, w, h (tiles of 8 x 8), place (0 centre, 1 top, 2 bottom), zoom (0 / 1):
              only this part is shown; w = 0 ends the popup

 Bitmap: 256 x 128, u8g2 page layout (16 pages of 8 lines; byte x of a page = column x, bit 0
 at the top): byte address = page x 256 + column.
*/

module kg_l2_osd (
	input wire clk,

	input wire sel,
	input wire stb,
	input wire [7:0] cmd,
	input wire [9:0] n,
	input wire [7:0] d,

	output reg osd_wr = 1'b0,
	output reg [11:0] osd_waddr = 12'd0,
	output reg [7:0] osd_wdata = 8'd0,
	output reg osd_en = 1'b0,
	output reg [23:0] osd_fg = 24'hFFFFFF,
	output reg [23:0] osd_bg = 24'h000040,
	output reg [1:0] osd_alpha = 2'd2,
	output reg [4:0] osd_px = 5'd0,   // the popup window, tiles
	output reg [3:0] osd_py = 4'd0,
	output reg [5:0] osd_pw = 6'd0,   // 0 = no popup
	output reg [4:0] osd_ph = 5'd0,
	output reg [1:0] osd_place = 2'd0,
	output reg osd_zoom = 1'b0
);

reg [7:0] t_lo = 8'd0;
reg [11:0] wa = 12'd0;
reg [23:0] fg = 24'd0;
reg [23:0] bg = 24'd0;
reg [4:0] px = 5'd0;
reg [3:0] py = 4'd0;
reg [5:0] pw = 6'd0;
reg [4:0] ph = 5'd0;
reg [1:0] place = 2'd0;

always @(posedge clk) begin
	osd_wr <= 1'b0;
	if (sel && stb)
		case (cmd)
			8'h01: if (n == 10'd0) osd_en <= d[0];
			8'h02:
				if (n == 10'd0)
					t_lo <= d;
				else if (n == 10'd1)
					wa <= { d[0], t_lo, 3'b000 };   // 512 tiles of 8 bytes
				else begin
					osd_waddr <= wa;
					osd_wdata <= d;
					osd_wr <= 1'b1;
					wa <= wa + 1'b1;
				end
			8'h03:
				case (n)
					10'd0: fg[23:16] <= d;
					10'd1: fg[15:8] <= d;
					10'd2: fg[7:0] <= d;
					10'd3: bg[23:16] <= d;
					10'd4: bg[15:8] <= d;
					10'd5: bg[7:0] <= d;
					10'd6: begin
						osd_fg <= fg;
						osd_bg <= bg;
						osd_alpha <= d[1:0];
					end
					default: ;
				endcase
			8'h04:
				case (n)
					10'd0: px <= d[4:0];
					10'd1: py <= d[3:0];
					10'd2: pw <= d[5:0];
					10'd3: ph <= d[4:0];
					10'd4: place <= d[1:0];
					10'd5: begin
						osd_px <= px;
						osd_py <= py;
						osd_pw <= pw;
						osd_ph <= ph;
						osd_place <= place;
						osd_zoom <= d[0];
					end
					default: ;
				endcase
			default: ;
		endcase
end

endmodule
