`timescale 1ns / 1ps

/*
 tb_kg_l2_rtc_aux.v

 RTC and AUX of link v2: kg_mcu2 with ENABLE_RTC and ENABLE_AUX and a model of the mcu.
 RTC: SET of ten registers in one packet read by the core, writes of the core as GET (not
 register C), IRQ bit 6. AUX: the frames of v1 (BITPLAN, PIXEL, CTL update + brightness, the
 peaks L / R, the debug values) as CHANGED, MATRIX, PEAKS (the highest since the last read),
 DEBUG, IRQ bit 7. Prints "tb_kg_l2_rtc_aux: 0 errors".
*/

module tb_kg_l2_rtc_aux;

reg clk = 1'b0;      // 28 MHz
always #17.86 clk = ~clk;

integer errors = 0;
task check(input [255:0] what, input [63:0] got, input [63:0] want);
	if (got !== want) begin
		$display("ERROR %0s: got %h, want %h", what, got, want);
		errors = errors + 1;
	end
endtask

reg sck = 1'b0, mosi = 1'b0, ss = 1'b1;
wire miso, int_line;

reg [7:0] rtc_a = 8'd0, rtc_di = 8'd0;
reg rtc_cs = 1'b0, rtc_wr_n = 1'b1;
wire [7:0] rtc_do;
reg [23:0] mcmd = 24'd0;
reg mcmd_wr = 1'b0;
reg [15:0] dbg_a = 16'd0, dbg_d = 16'd0;

kg_mcu2 #(.ENABLE_OSD(0), .ENABLE_RTC(1), .ENABLE_AUX(1)) dut(
	.CLK(clk), .N_RESET(1'b1),
	.MCU_SCK(sck), .MCU_MOSI(mosi), .MCU_MISO(miso), .MCU_SS(ss), .MCU_INT(int_line),
	.MCU_SPI_FT_SS(1'b1), .MCU_SPI_SD2_SS(1'b1),
	.SW(), .SW_WR(), .SW_INDEX(), .SW_VALUE(), .HW_ID(), .DVI_ONLY(), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(), .BTNS(), .RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),
	.KBD(), .KBD_WR(), .PS2_CODE(), .PS2_KIND(), .PS2_WR(), .MS_X(), .MS_Y(), .MS_Z(), .MS_B(),
	.MS_WR(), .JOY_L(), .JOY_R(), .JOY_WR(), .PS2_CMD(16'd0), .PS2_CMD_WR(1'b0),
	.LD_KIND(), .LD_SLOT(), .LD_SIZE(), .LD_START(), .LD_ACTIVE(), .LD_END(), .LD_ADDR(),
	.LD_DATA(), .LD_WR(), .LD_READY(1'b1),
	.OSD_WR(), .OSD_WADDR(), .OSD_WDATA(), .OSD_EN(), .OSD_FG(), .OSD_BG(), .OSD_ALPHA(),
	.OSD_PX(), .OSD_PY(), .OSD_PW(), .OSD_PH(), .OSD_PLACE(), .OSD_ZOOM(),
	.SDC_IMG_MOUNTED(), .SDC_IMG_SIZE(), .SDC_RD(8'd0), .SDC_WR(8'd0), .SDC_SECTOR(32'd0),
	.SDC_BUSY(), .SDC_DONE(), .SDC_ERROR(), .SDC_SLOT(), .SDC_BYTE_IN_STROBE(), .SDC_BYTE_ADDR(),
	.SDC_BYTE_IN_DATA(), .SDC_BYTE_OUT_DATA(8'd0), .IMG_WP(), .IMG_PHYS_WR(), .IMG_PHYS(),
	.IMG_FLUSH(), .FDD_CHNG_WR(), .FDD_CHNG(), .FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0), .IMG_ACTIVE(),
	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'd0), .PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0),
	.PORT_IN_FULL(), .PORT_CFG(128'd0), .PORT_STAT(), .PORT_STAT_WR(),
	.RTC_A(rtc_a), .RTC_DI(rtc_di), .RTC_DO(rtc_do), .RTC_CS(rtc_cs), .RTC_WR_N(rtc_wr_n),
	.MATRIX_CMD(mcmd), .MATRIX_CMD_WR(mcmd_wr), .DEBUG_ADDR(dbg_a), .DEBUG_DATA(dbg_d),
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



task irq_bits(output [7:0] bits);
	begin
		tx[0] = 8'h00; tx[1] = 8'h01; tx[2] = 8'h00; tx[3] = 8'h00; tx[4] = 8'h00;
		packet(5);
		bits = rx[4];
	end
endtask

// a command that answers: T C Z, then n bytes; rx[3 + k] = payload 1 + k
task read(input [7:0] t, input [7:0] c, input integer cnt);
	integer i;
	begin
		tx[0] = t; tx[1] = c;
		for (i = 2; i < 3 + cnt; i = i + 1) tx[i] = 0;
		packet(3 + cnt);
	end
endtask

task frame(input [23:0] f);
	begin
		@(posedge clk); mcmd <= f; mcmd_wr <= 1'b1;
		@(posedge clk); mcmd_wr <= 1'b0;
	end
endtask

task core_rd(input [7:0] a, output [7:0] v);
	begin
		@(posedge clk); rtc_a <= a;
		@(posedge clk); @(posedge clk); v = rtc_do;
	end
endtask

task core_wr(input [7:0] a, input [7:0] v);
	begin
		@(posedge clk); rtc_a <= a; rtc_di <= v; rtc_cs <= 1'b1; rtc_wr_n <= 1'b0;
		@(posedge clk); rtc_cs <= 1'b0; rtc_wr_n <= 1'b1;
	end
endtask

integer i;
reg [7:0] bits, v;
initial begin
	#2000;
	// STATUS caps: RTC (bit 5) and AUX (bit 6)
	read(8'h00, 8'h00, 8);
	check("caps", rx[6], 8'h60);

	// ---- RTC ----
	tx[0] = 8'h06; tx[1] = 8'h01; tx[2] = 8'd0;
	for (i = 0; i < 11; i = i + 1) tx[3 + i] = 8'h11 + i;
	packet(14);
	core_rd(8'd0, v); check("reg 0", v, 8'h11);
	core_rd(8'd5, v); check("reg 5", v, 8'h16);
	core_rd(8'd9, v); check("reg 9", v, 8'h1A);
	irq_bits(bits); check("no RTC irq", bits[6], 1'b0);
	core_wr(8'h0A, 8'h77); // while busy (the mcu sets the clock): not taken
	core_rd(8'h0A, v); check("not while busy", v, 8'h1B);
	tx[0] = 8'h00; tx[1] = 8'h05; tx[2] = 8'h00; packet(3); // INIT done
	core_wr(8'h0B, 8'h82);
	core_wr(8'h0C, 8'h55); // not sent
	core_rd(8'h0B, v); check("reg B written", v, 8'h82);
	irq_bits(bits); check("RTC irq", bits[6], 1'b1);
	read(8'h06, 8'h02, 17);
	check("GET count", rx[3], 8'd1);
	check("GET reg", rx[4], 8'h0B);
	check("GET value", rx[5], 8'h82);
	irq_bits(bits); check("RTC irq low", bits[6], 1'b0);

	// ---- AUX ----
	irq_bits(bits); check("no AUX irq", bits[7], 1'b0);
	frame({ 8'h62, 8'd3, 8'hA5 });           // BITPLAN byte 3
	frame({ 8'h61, 8'h29, 8'd2 });           // PIXEL x 9 y 2 yellow
	frame({ 8'h60, 8'd0, 8'h76 });           // CTL brightness 7 + update
	irq_bits(bits); check("AUX irq", bits[7], 1'b1);
	read(8'h07, 8'h04, 1); check("CHANGED matrix", rx[3], 8'h01);
	read(8'h07, 8'h01, 33);
	check("ctl", rx[3], 8'h74);
	check("plane 3", rx[4 + 3], 8'hA5);
	check("plane 18 (right red y 2)", rx[4 + 18], 8'h02);
	check("plane 26 (right green y 2)", rx[4 + 26], 8'h02);
	check("plane 2", rx[4 + 2], 8'h00);
	read(8'h07, 8'h04, 1); check("CHANGED clear", rx[3], 8'h00);
	read(8'h07, 8'h01, 1); check("brightness flag once", rx[3], 8'h70);

	frame({ 8'h70, 16'h1234 });
	frame({ 8'h70, 16'h0100 });
	frame({ 8'h71, 16'h00FF });
	read(8'h07, 8'h04, 1); check("CHANGED peaks", rx[3], 8'h02);
	read(8'h07, 8'h02, 4);
	check("peak L", { rx[4], rx[3] }, 16'h1234);
	check("peak R", { rx[6], rx[5] }, 16'h00FF);
	read(8'h07, 8'h02, 4);
	check("peaks cleared", { rx[4], rx[3] }, 16'h0000);

	@(posedge clk); dbg_a <= 16'hBEEF; dbg_d <= 16'h1234;
	#200;
	read(8'h07, 8'h04, 1); check("CHANGED debug", rx[3], 8'h04);
	read(8'h07, 8'h03, 4);
	check("debug addr", { rx[4], rx[3] }, 16'hBEEF);
	check("debug data", { rx[6], rx[5] }, 16'h1234);
	irq_bits(bits); check("AUX irq low", bits[7], 1'b0);

	$display("tb_kg_l2_rtc_aux: %0d errors", errors);
	$finish;
end

endmodule
