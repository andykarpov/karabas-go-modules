`timescale 1ns / 1ps

/*
 tb_kg_l2_osd.v

 The bitmap OSD of link v2: the mcu writes the bitmap, the colours, ENABLE and a POPUP through
 kg_mcu2 (target 02), kg_l2_osd_overlay draws it over an 800 x 600 picture. Checked on the
 screen: the video without OSD, the scale (2 at 800 x 600) and the centre, text and background
 pixels (alpha 1 = a half; 3 = opaque), the border, the shadow, the last pixel of the bitmap, a popup at the top with
 zoom (scale 4). Prints "tb_kg_l2_osd: 0 errors".
*/

module tb_kg_l2_osd;

reg clk = 1'b0;      // the link clock, 28 MHz
always #17.86 clk = ~clk;
reg vclk = 1'b0;     // the pixel clock (fast, for a short simulation)
always #5 vclk = ~vclk;

integer errors = 0;
task check(input [255:0] what, input [31:0] got, input [31:0] want);
	if (got !== want) begin
		$display("ERROR %0s: got %h, want %h", what, got, want);
		errors = errors + 1;
	end
endtask

// ---------------- the link ----------------

reg sck = 1'b0, mosi = 1'b0, ss = 1'b1;
wire miso, int_line;
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

kg_mcu2 dut(
	.CLK(clk), .N_RESET(1'b1),
	.MCU_SCK(sck), .MCU_MOSI(mosi), .MCU_MISO(miso), .MCU_SS(ss), .MCU_INT(int_line),
	.MCU_SPI_FT_SS(1'b1), .MCU_SPI_SD2_SS(1'b1),
	.SW(), .SW_WR(), .SW_INDEX(), .SW_VALUE(), .HW_ID(), .DVI_ONLY(), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(), .BTNS(), .RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),
	.KBD(), .KBD_WR(), .PS2_CODE(), .PS2_KIND(), .PS2_WR(), .MS_X(), .MS_Y(), .MS_Z(), .MS_B(),
	.MS_WR(), .JOY_L(), .JOY_R(), .JOY_WR(), .PS2_CMD(16'd0), .PS2_CMD_WR(1'b0),
	.LD_KIND(), .LD_SLOT(), .LD_SIZE(), .LD_START(), .LD_ACTIVE(), .LD_END(), .LD_ADDR(),
	.LD_DATA(), .LD_WR(), .LD_READY(1'b1),
	.OSD_WR(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha), .OSD_PX(osd_px), .OSD_PY(osd_py),
	.OSD_PW(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),
	.SDC_RD(8'd0), .SDC_WR(8'd0), .SDC_SECTOR(32'd0), .SDC_BYTE_OUT_DATA(8'd0),
	.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0),
	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'd0), .PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0),
	.PORT_IN_FULL(), .PORT_CFG(128'd0), .PORT_STAT(), .PORT_STAT_WR(),
	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_DO(), .RTC_CS(1'b0), .RTC_WR_N(1'b1),
	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),
	.FT_SPI_ON(), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(), .FT_MISO(1'b1), .FT_CS_N(),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

reg [7:0] tx [0:1023];
reg [7:0] rx [0:1023];

task xbyte(input [7:0] b, output [7:0] r);
	integer i;
	begin
		for (i = 7; i >= 0; i = i - 1) begin
			mosi = b[i];
			#16; sck = 1'b1; r[i] = miso;
			#16; sck = 1'b0;
		end
	end
endtask

task packet(input integer len);
	integer i;
	reg [7:0] r;
	begin
		ss = 1'b0; #16;
		for (i = 0; i < len; i = i + 1) begin
			xbyte(tx[i], r);
			rx[i] = r;
		end
		#16; ss = 1'b1; #1000;
	end
endtask

// ---------------- the video: 800 x 600 of 1056 x 628 ----------------

reg [10:0] hc = 11'd0, vc = 11'd0;
always @(posedge vclk) begin
	if (hc == 11'd1055) begin
		hc <= 11'd0;
		vc <= (vc == 11'd627) ? 11'd0 : vc + 1'b1;
	end
	else
		hc <= hc + 1'b1;
end
wire de = hc < 11'd800 && vc < 11'd600;
wire hs = hc >= 11'd840 && hc < 11'd968;
wire vs = vc >= 11'd601 && vc < 11'd605;
wire [23:0] vid = de ? { hc[7:0], vc[7:0], 8'h80 } : 24'd0;

wire [23:0] rgb_o;
wire hs_o, vs_o, de_o;
kg_l2_osd_overlay u_ov(
	.wclk(clk), .osd_wr(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha), .osd_px(osd_px), .osd_py(osd_py),
	.osd_pw(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.clk(vclk), .rgb_i(vid), .hs_i(hs), .vs_i(vs), .de_i(de),
	.rgb_o(rgb_o), .hs_o(hs_o), .vs_o(vs_o), .de_o(de_o)
);

// the screen as it comes out (2 clocks later than its pixel)
reg [10:0] hc1 = 0, hc2 = 0, vc1 = 0, vc2 = 0;
reg [23:0] scr [0:600*800-1];
always @(posedge vclk) begin
	hc1 <= hc; hc2 <= hc1; vc1 <= vc; vc2 <= vc1;
	if (hc2 < 800 && vc2 < 600) scr[vc2 * 800 + hc2] <= rgb_o;
end

task frames(input integer n);
	integer i;
	begin
		for (i = 0; i < n; i = i + 1) begin
			@(posedge vclk); while (!(vc == 11'd605 && hc == 11'd0)) @(posedge vclk);
		end
	end
endtask

function [23:0] v_at(input integer x, input integer y);
	v_at = { x[7:0], y[7:0], 8'h80 };
endfunction

function [7:0] half(input [7:0] a, input [7:0] b);
	half = ({ 1'b0, a } + { 1'b0, b }) >> 1;
endfunction

function [23:0] mix2(input [23:0] o, input [23:0] v);
	mix2 = { half(o[23:16], v[23:16]), half(o[15:8], v[15:8]), half(o[7:0], v[7:0]) };
endfunction

function [23:0] dark(input [23:0] v);
	dark = { 1'b0, v[23:17], 1'b0, v[15:9], 1'b0, v[7:1] };
endfunction

integer i;
initial begin
	#2000;
	frames(2);
	check("no OSD", scr[300 * 800 + 400], v_at(400, 300));

	// the bitmap: pixel (0, 0) and pixel (255, 127); a byte in page 1 at column 16 for the popup
	tx[0] = 8'h02; tx[1] = 8'h02; tx[2] = 8'h00; tx[3] = 8'h00; tx[4] = 8'h01; packet(5);
	tx[0] = 8'h02; tx[1] = 8'h02; tx[2] = 8'hFF; tx[3] = 8'h01;
	for (i = 0; i < 8; i = i + 1) tx[4 + i] = (i == 7) ? 8'h80 : 8'h00;
	packet(12);
	tx[0] = 8'h02; tx[1] = 8'h02; tx[2] = 8'd34; tx[3] = 8'h00; tx[4] = 8'h01; packet(5); // tile 32 + 2 = page 1, column 16
	// colours: fg red, bg blue, alpha 1 (a half)
	tx[0] = 8'h02; tx[1] = 8'h03; tx[2] = 8'hFF; tx[3] = 0; tx[4] = 0; tx[5] = 0; tx[6] = 0; tx[7] = 8'hFF; tx[8] = 1;
	packet(9);
	tx[0] = 8'h02; tx[1] = 8'h01; tx[2] = 8'h01; packet(3);

	frames(2);
	// scale 2: 512 x 256 at (144, 172)
	check("text (0,0)", scr[172 * 800 + 144], 24'hFF0000);
	check("text (0,0) 2x2", scr[173 * 800 + 145], 24'hFF0000);
	check("bg next to it", scr[172 * 800 + 146], mix2(24'h0000FF, v_at(146, 172)));
	check("last pixel", scr[(172 + 255) * 800 + 144 + 511], 24'hFF0000);
	check("border", scr[172 * 800 + 142], mix2(24'h0000FF, v_at(142, 172)));
	check("outside the border", scr[172 * 800 + 139], v_at(139, 172));
	check("shadow", scr[200 * 800 + 662], dark(v_at(662, 200)));
	check("right of the shadow", scr[200 * 800 + 669], v_at(669, 200));

	// popup: tiles x 2, y 1, 4 x 2 (32 x 16), top, zoom: scale 4, 128 x 64 at (336, 32)
	tx[0] = 8'h02; tx[1] = 8'h04; tx[2] = 2; tx[3] = 1; tx[4] = 4; tx[5] = 2; tx[6] = 1; tx[7] = 1;
	packet(8);
	frames(2);
	check("popup pixel", scr[32 * 800 + 336], 24'hFF0000);
	check("popup pixel 4x4", scr[35 * 800 + 339], 24'hFF0000);
	check("popup bg", scr[32 * 800 + 340], mix2(24'h0000FF, v_at(340, 32)));
	check("not the old place", scr[172 * 800 + 144], v_at(144, 172));

	// alpha 3: the background is opaque
	tx[0] = 8'h02; tx[1] = 8'h03; tx[2] = 8'hFF; tx[3] = 0; tx[4] = 0; tx[5] = 0; tx[6] = 0; tx[7] = 8'hFF; tx[8] = 3;
	packet(9);
	frames(2);
	check("opaque bg", scr[32 * 800 + 340], 24'h0000FF);

	// the popup ends, the OSD goes off
	tx[0] = 8'h02; tx[1] = 8'h04; tx[2] = 0; tx[3] = 0; tx[4] = 0; tx[5] = 0; tx[6] = 0; tx[7] = 0; packet(8);
	tx[0] = 8'h02; tx[1] = 8'h01; tx[2] = 8'h00; packet(3);
	frames(2);
	check("off again", scr[172 * 800 + 144], v_at(144, 172));

	$display("tb_kg_l2_osd: %0d errors", errors);
	$finish;
end

endmodule
