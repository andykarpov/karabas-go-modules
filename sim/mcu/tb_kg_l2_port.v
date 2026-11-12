`timescale 1ns / 1ps

/*
 tb_kg_l2_port.v

 The byte streams of link v2: kg_mcu2 with all four ports (target 05, kg_l2_port) and a model of
 the mcu. Checked: STATUS (free room, bytes waiting, config), PUT into a ready core in order, PUT
 past the room of a core that is not ready (the rest dropped, then all of it out), the bytes of
 the core as IRQ bit 5 and GET (also past what waits), the ports apart, PSTAT.
 Prints "tb_kg_l2_port: 0 errors".
*/

module tb_kg_l2_port;

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

wire [31:0] out_data, stat;
wire [3:0] out_wr, in_full, stat_wr;
reg [3:0] out_ready = 4'b1111;
reg [31:0] in_data = 32'd0;
reg [3:0] in_wr = 4'd0;
reg [127:0] cfg = 128'd0;

kg_mcu2 #(.ENABLE_OSD(0), .ENABLE_PORTS(4'b1111)) dut(
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
	.PORT_OUT_DATA(out_data), .PORT_OUT_WR(out_wr), .PORT_OUT_READY(out_ready),
	.PORT_IN_DATA(in_data), .PORT_IN_WR(in_wr), .PORT_IN_FULL(in_full), .PORT_CFG(cfg),
	.PORT_STAT(stat), .PORT_STAT_WR(stat_wr),
	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_DO(), .RTC_CS(1'b0), .RTC_WR_N(1'b1),
	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),
	.FT_SPI_ON(), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(), .FT_MISO(1'b1), .FT_CS_N(),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

// what the core got, per port
reg [7:0] got [0:255]; // port p at p * 64
integer got_n [0:3];
integer p;
initial for (p = 0; p < 4; p = p + 1) got_n[p] = 0;
always @(posedge clk)
	for (p = 0; p < 4; p = p + 1)
		if (out_wr[p]) begin
			got[p * 64 + got_n[p]] = out_data[p*8 +: 8];
			got_n[p] = got_n[p] + 1;
		end
reg [7:0] stat_seen = 8'd0;
always @(posedge clk) if (stat_wr[3]) stat_seen <= stat[31:24];

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


// STATUS: T C port Z free avail cfg x 4
reg [7:0] st_free, st_avail;
reg [31:0] st_cfg;
task status(input [7:0] port);
	begin
		tx[0] = 8'h05; tx[1] = 8'h01; tx[2] = port; tx[3] = 0; tx[4] = 0; tx[5] = 0; tx[6] = 0; tx[7] = 0; tx[8] = 0; tx[9] = 0;
		packet(10);
		st_free = rx[4]; st_avail = rx[5]; st_cfg = { rx[9], rx[8], rx[7], rx[6] };
	end
endtask

task put(input [7:0] port, input integer cnt, input [7:0] base);
	integer i;
	begin
		tx[0] = 8'h05; tx[1] = 8'h02; tx[2] = port;
		for (i = 0; i < cnt; i = i + 1) tx[3 + i] = base + i;
		packet(3 + cnt);
	end
endtask

// GET: T C port count Z bytes
task get(input [7:0] port, input integer cnt);
	integer i;
	begin
		tx[0] = 8'h05; tx[1] = 8'h03; tx[2] = port; tx[3] = cnt;
		for (i = 4; i < 5 + cnt; i = i + 1) tx[i] = 0;
		packet(5 + cnt);
	end
endtask

task irq_bits(output [7:0] bits);
	begin
		tx[0] = 8'h00; tx[1] = 8'h01; tx[2] = 8'h00; tx[3] = 8'h00; tx[4] = 8'h00;
		packet(5);
		bits = rx[4];
	end
endtask

integer i;
reg [7:0] bits;
reg ok;
initial begin
	#2000;
	cfg[31:0] = 32'h0000_1234;
	status(8'd0);
	check("port 0 free", st_free, 8'd32);
	check("port 0 avail", st_avail, 8'd0);
	check("port 0 cfg", st_cfg, 32'h0000_1234);
	tx[0] = 8'h00; tx[1] = 8'h00; for (i = 2; i < 12; i = i + 1) tx[i] = 0; packet(12);
	check("STATUS ports mask", rx[10], 8'h0F);

	// PUT into a ready core: in order
	put(8'd1, 3, 8'h41);
	#500;
	check("port 1 got 3", got_n[1], 3);
	check("port 1 byte 0", got[64 + 0], 8'h41);
	check("port 1 byte 2", got[64 + 2], 8'h43);
	check("port 2 untouched", got_n[2], 0);

	// PUT past the room of a core that is not ready
	out_ready[2] = 1'b0;
	put(8'd2, 40, 8'h10);
	status(8'd2);
	check("port 2 full", st_free, 8'd0);
	out_ready[2] = 1'b1;
	#2000;
	check("port 2 got 32", got_n[2], 32);
	ok = 1'b1;
	for (i = 0; i < 32; i = i + 1) if (got[128 + i] !== 8'h10 + i) ok = 1'b0;
	check("port 2 bytes", ok, 1'b1);
	status(8'd2);
	check("port 2 free again", st_free, 8'd32);

	// the core sends 5 bytes on port 1
	for (i = 0; i < 5; i = i + 1) begin
		@(posedge clk); in_data[15:8] <= 8'hA0 + i; in_wr[1] <= 1'b1;
		@(posedge clk); in_wr[1] <= 1'b0;
	end
	#200;
	irq_bits(bits);
	check("IRQ bit 5", bits[5], 1'b1);
	status(8'd1);
	check("port 1 avail 5", st_avail, 8'd5);
	status(8'd0);
	check("port 0 avail 0", st_avail, 8'd0);
	get(8'd1, 3);
	check("get 0", rx[5], 8'hA0);
	check("get 2", rx[7], 8'hA2);
	get(8'd1, 5);
	check("get 3", rx[5], 8'hA3);
	check("get 4", rx[6], 8'hA4);
	check("get past", rx[7], 8'h00);
	irq_bits(bits);
	check("IRQ bit 5 low", bits[5], 1'b0);

	// PSTAT of the printer
	tx[0] = 8'h05; tx[1] = 8'h04; tx[2] = 8'd3; tx[3] = 8'h80; packet(4);
	check("printer status", stat_seen, 8'h80);

	$display("tb_kg_l2_port: %0d errors", errors);
	$finish;
end

endmodule
