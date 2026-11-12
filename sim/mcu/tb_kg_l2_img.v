`timescale 1ns / 1ps

/*
 tb_kg_l2_img.v

 The file mounter of link v2: kg_mcu2 with ENABLE_IMG (target 03, kg_l2_img) and a model of the
 mcu, against the sector interface (sdc_*) of a model of a drive. Checked: MOUNT (size, write
 protection, a physical drive), a read request as an event, a RDATA with a bad sum refused and
 the request raised again, a good one taken and passed to the drive after DONE, a write request
 (the sector copied from the drive, read by WDATA with its sum, DONE), DSKCHG as an event and its
 answer, FLUSH, the IMG bit of SYS IRQ low when nothing waits. Prints "tb_kg_l2_img: 0 errors".
*/

module tb_kg_l2_img;

reg clk = 1'b0;      // 28 MHz
always #17.86 clk = ~clk;

integer errors = 0;
task check(input [255:0] what, input [63:0] got, input [63:0] want);
	if (got !== want) begin
		$display("ERROR %0s: got %h, want %h", what, got, want);
		errors = errors + 1;
	end
endtask

// ---------------- the dut ----------------

reg sck = 1'b0, mosi = 1'b0, ss = 1'b1;
wire miso, int_line;

wire [7:0] sdc_img_mounted, img_wp, img_flush;
wire [63:0] sdc_img_size;
reg [7:0] sdc_rd = 8'd0, sdc_wr = 8'd0;
reg [31:0] sdc_sector = 32'd0;
wire sdc_busy, sdc_done, sdc_error, sdc_strobe, phys_wr, chng_wr, img_active;
wire [2:0] sdc_slot;
wire [8:0] sdc_addr;
wire [7:0] sdc_in;
wire [15:0] img_phys, fdd_chng;
reg chng_req = 1'b0;
reg [1:0] chng_ds = 2'd0;

// the drive: its sector to write is addr ^ 8'h5A, two registers after the address (OUT_LATENCY 3:
// sampled in the third clock)
reg [7:0] out_d1 = 0, out_d2 = 0;
always @(posedge clk) begin
	out_d1 <= sdc_addr[7:0] ^ 8'h5A ^ { 7'd0, sdc_addr[8] };
	out_d2 <= out_d1;
end

kg_mcu2 #(.CAPS(16'h0005), .ENABLE_OSD(0), .ENABLE_IMG(1), .IMG_OUT_LATENCY(3)) dut(
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
	.SDC_IMG_MOUNTED(sdc_img_mounted), .SDC_IMG_SIZE(sdc_img_size), .SDC_RD(sdc_rd), .SDC_WR(sdc_wr),
	.SDC_SECTOR(sdc_sector), .SDC_BUSY(sdc_busy), .SDC_DONE(sdc_done), .SDC_ERROR(sdc_error),
	.SDC_SLOT(sdc_slot), .SDC_BYTE_IN_STROBE(sdc_strobe), .SDC_BYTE_ADDR(sdc_addr),
	.SDC_BYTE_IN_DATA(sdc_in), .SDC_BYTE_OUT_DATA(out_d2),
	.IMG_WP(img_wp), .IMG_PHYS_WR(phys_wr), .IMG_PHYS(img_phys), .IMG_FLUSH(img_flush),
	.FDD_CHNG_WR(chng_wr), .FDD_CHNG(fdd_chng), .FDD_CHNG_REQ(chng_req), .FDD_CHNG_DS(chng_ds),
	.IMG_ACTIVE(img_active),
	.FT_SPI_ON(), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(), .FT_MISO(1'b1), .FT_CS_N(),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

// what the core side saw
reg [7:0] rd_buf [0:511];
integer rd_count = 0, done_count = 0;
reg last_error = 1'b0;
reg [7:0] mounted_seen = 8'd0, flush_seen = 8'd0;
reg [63:0] size_seen = 64'd0;
reg [15:0] phys_seen = 16'd0, chng_seen = 16'd0;
always @(posedge clk) begin
	if (sdc_strobe) begin
		rd_buf[sdc_addr] <= sdc_in;
		rd_count = rd_count + 1;
	end
	if (sdc_done) begin
		done_count = done_count + 1;
		last_error <= sdc_error;
	end
	if (|sdc_img_mounted) begin
		mounted_seen <= mounted_seen | sdc_img_mounted;
		size_seen <= sdc_img_size;
	end
	if (|img_flush) flush_seen <= flush_seen | img_flush;
	if (phys_wr) phys_seen <= img_phys;
	if (chng_wr) chng_seen <= fdd_chng;
	// a request is held until it is taken
	if (sdc_busy) begin
		sdc_rd <= 8'd0;
		sdc_wr <= 8'd0;
	end
end

// ---------------- the mcu ----------------

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

function [7:0] pat(input integer i);
	pat = i[7:0] + 8'h31 + { 7'd0, i[8] };
endfunction

// EVENT: T C Z kind slot lba x 4: payload m at packet byte m + 2
task event_read(output [7:0] kind, output [7:0] slot, output [31:0] arg);
	integer i;
	begin
		tx[0] = 8'h03; tx[1] = 8'h02;
		for (i = 2; i < 9; i = i + 1) tx[i] = 8'h00;
		packet(9);
		kind = rx[3]; slot = rx[4]; arg = { rx[8], rx[7], rx[6], rx[5] };
	end
endtask

// RDATA: T C slot 512 bytes sum lo hi Z status
task rdata(input [7:0] slot, input bad, output [7:0] status);
	integer i;
	reg [15:0] sum;
	begin
		sum = 16'd0;
		tx[0] = 8'h03; tx[1] = 8'h03; tx[2] = slot;
		for (i = 0; i < 512; i = i + 1) begin
			tx[3 + i] = pat(i);
			sum = sum + pat(i);
		end
		if (bad) sum = sum + 1'b1;
		tx[515] = sum[7:0]; tx[516] = sum[15:8]; tx[517] = 8'h00; tx[518] = 8'h00;
		packet(519);
		status = rx[518];
	end
endtask

task done(input [7:0] slot, input [7:0] st);
	begin
		tx[0] = 8'h03; tx[1] = 8'h05; tx[2] = slot; tx[3] = st; packet(4);
	end
endtask

// SYS IRQ (no ack): the pending bits of the targets, bit 3 = IMG
task img_irq(output bit);
	begin
		tx[0] = 8'h00; tx[1] = 8'h01; tx[2] = 8'h00; tx[3] = 8'h00; tx[4] = 8'h00;
		packet(5);
		bit = rx[4][3];
	end
endtask

integer i, k;
reg b;
reg [7:0] kind, slot, st;
reg [31:0] arg;
reg [15:0] sum;
reg ok;
initial begin
	#2000;
	img_irq(b); check("INT low at start", b, 1'b0);

	// MOUNT slot 1, 174848 bytes, write protected
	tx[0] = 8'h03; tx[1] = 8'h01; tx[2] = 8'd1;
	tx[3] = 8'h00; tx[4] = 8'hAB; tx[5] = 8'h02; for (i = 6; i < 11; i = i + 1) tx[i] = 8'h00;
	tx[11] = 8'h01;
	packet(12);
	check("mounted", mounted_seen, 8'h02);
	check("size", size_seen, 64'd174848);
	check("wp", img_wp, 8'h02);
	// MOUNT slot 2 on the physical drive DS1, size 0
	tx[0] = 8'h03; tx[1] = 8'h01; tx[2] = 8'd2; for (i = 3; i < 11; i = i + 1) tx[i] = 8'h00;
	tx[11] = 8'h04;
	packet(12);
	check("phys", phys_seen, 16'h0202);
	check("wp of slot 2", img_wp, 8'h02);

	// ---- a read of slot 0, LBA 12345678 ----
	@(posedge clk); sdc_sector <= 32'h12345678; sdc_rd <= 8'h01;
	#3000;
	check("busy", sdc_busy, 1'b1);
	img_irq(b); check("INT for the read", b, 1'b1);
	event_read(kind, slot, arg);
	check("event kind read", kind, 8'd1);
	check("event slot", slot, 8'd0);
	check("event lba", arg, 32'h12345678);
	img_irq(b); check("INT after the event", b, 1'b0);
	rdata(8'd0, 1'b1, st);
	check("bad sum refused", st, 8'd1);
	done(8'd0, 8'd1);  // done, but the data was refused: the request again
	#2000;
	img_irq(b); check("INT again", b, 1'b1);
	check("no bytes yet", rd_count, 0);
	event_read(kind, slot, arg);
	check("event again", kind, 8'd1);
	rdata(8'd0, 1'b0, st);
	check("good sum taken", st, 8'd0);
	done(8'd0, 8'd1);
	#100000;
	check("512 bytes", rd_count, 512);
	check("done", done_count, 1);
	check("no error", last_error, 1'b0);
	ok = 1'b1;
	for (i = 0; i < 512; i = i + 1) if (rd_buf[i] !== pat(i)) ok = 1'b0;
	check("the sector read", ok, 1'b1);

	// ---- a write of slot 3, LBA 7 ----
	@(posedge clk); sdc_sector <= 32'd7; sdc_wr <= 8'h08;
	#100000;
	img_irq(b); check("INT for the write", b, 1'b1);
	event_read(kind, slot, arg);
	check("event kind write", kind, 8'd2);
	check("event slot 3", slot, 8'd3);
	check("event lba 7", arg, 32'd7);
	tx[0] = 8'h03; tx[1] = 8'h04; tx[2] = 8'd3;
	for (i = 3; i < 518; i = i + 1) tx[i] = 8'h00;
	packet(518);
	ok = 1'b1; sum = 16'd0;
	for (i = 0; i < 512; i = i + 1) begin
		k = (i[7:0] ^ 8'h5A ^ { 7'd0, i[8] });
		if (rx[4 + i] !== k[7:0]) ok = 1'b0;
		sum = sum + k[7:0];
	end
	check("the sector written", ok, 1'b1);
	if (!ok) for (i = 0; i < 6; i = i + 1) $display("  byte %0d: %h", i, rx[4 + i]);
	check("its sum", { rx[517], rx[516] }, sum);
	done(8'd3, 8'd1);
	#2000;
	check("write done", done_count, 2);
	check("write no error", last_error, 1'b0);
	check("not busy", sdc_busy, 1'b0);

	// a write answered "protected"
	@(posedge clk); sdc_sector <= 32'd8; sdc_wr <= 8'h02;
	#100000;
	event_read(kind, slot, arg);
	check("protected: slot 1", slot, 8'd1);
	done(8'd1, 8'd3);
	#2000;
	check("protected done", done_count, 3);
	check("protected error", last_error, 1'b1);

	// ---- DSKCHG ----
	@(posedge clk); chng_ds <= 2'd2; chng_req <= 1'b1;
	@(posedge clk); chng_req <= 1'b0;
	#2000;
	img_irq(b); check("INT for DSKCHG", b, 1'b1);
	event_read(kind, slot, arg);
	check("event kind dskchg", kind, 8'd5);
	check("dskchg drive", arg, 32'd2);
	tx[0] = 8'h03; tx[1] = 8'h07; tx[2] = 8'd2; tx[3] = 8'd1; packet(4);
	check("fdd_chng", chng_seen, 16'h0201);

	// ---- FLUSH, nothing waits ----
	tx[0] = 8'h03; tx[1] = 8'h06; tx[2] = 8'd5; packet(3);
	check("flush", flush_seen, 8'h20);
	event_read(kind, slot, arg);
	check("no event", kind, 8'd0);
	img_irq(b); check("INT low at the end", b, 1'b0);

	$display("tb_kg_l2_img: %0d errors", errors);
	$finish;
end

endmodule
