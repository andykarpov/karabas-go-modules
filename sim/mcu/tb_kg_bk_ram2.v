`timescale 1ns / 1ps

/*
 tb_kg_bk_ram2.v

 The backup RAM on link v2: kg_mcu2 (ENABLE_IMG, IMG_OUT_LATENCY 2) + kg_bk_ram with LINK 2 in
 slot 5, a model of the memory of the core (an aux port that acks after a few clocks) and a model
 of the mcu (karabas-go-firmware link_api.c v2_img_event, storage/bk_save.c). Checked:
 - start (4 sectors): IMG EVENT kind 4, slot 5, size 4, kind 0; busy until the file is in;
 - MOUNT of a 3 sector file: three read events (LBA 0..2), RDATA, DONE: the sectors in the
   memory, sector 3 untouched, busy ends, mounted;
 - a write of the core into sector 1: autosave after the idle time, a write event (LBA 1), WDATA
   gives the sector of the memory with its sum, DONE;
 - FLUSH with nothing dirty: EVENT kind 3, result 1;
 - a write into sector 2 and FLUSH at once: the write event first, then kind 3 result 1;
 - a write that fails (DONE 2 until the retries are spent) and FLUSH: kind 3 result 2,
   save_error, the sector saved again after it;
 - INT low at the end.
 Prints "tb_kg_bk_ram2: 0 errors".
*/

module tb_kg_bk_ram2;

reg clk = 1'b0;      // 28 MHz
always #17.86 clk = ~clk;

integer errors = 0;
task check(input [255:0] what, input [63:0] got, input [63:0] want);
	if (got !== want) begin
		$display("ERROR %0s: got %h, want %h", what, got, want);
		errors = errors + 1;
	end
endtask

localparam [2:0] SLOT = 3'd5;

// ---------------- the dut ----------------

reg sck = 1'b0, mosi = 1'b0, ss = 1'b1;
wire miso, int_line;

wire [7:0] sdc_img_mounted, img_flush, sdc_rd, sdc_wr, sdc_in, sdc_out;
wire [63:0] sdc_img_size;
wire [31:0] sdc_sector;
wire sdc_busy, sdc_done, sdc_error, sdc_strobe;
wire [2:0] sdc_slot;
wire [8:0] sdc_addr;
wire bk_mount, bk_flushed;
wire [31:0] bk_size;
wire [7:0] bk_kind, bk_result;

kg_mcu2 #(.CAPS(16'h0003), .ENABLE_OSD(0), .ENABLE_IMG(1), .IMG_OUT_LATENCY(2)) mcu(
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
	.SDC_BYTE_IN_DATA(sdc_in), .SDC_BYTE_OUT_DATA(sdc_out),
	.IMG_WP(), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(img_flush),
	.FDD_CHNG_WR(), .FDD_CHNG(), .FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0),
	.BK_MOUNT(bk_mount), .BK_FLUSHED(bk_flushed), .BK_SLOT(SLOT), .BK_SIZE(bk_size),
	.BK_KIND(bk_kind), .BK_RESULT(bk_result),
	.IMG_ACTIVE(),
	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'd0), .PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0),
	.PORT_IN_FULL(), .PORT_CFG(128'd0), .PORT_STAT(), .PORT_STAT_WR(),
	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_DO(), .RTC_CS(1'b0), .RTC_WR_N(1'b1),
	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),
	.FT_SPI_ON(), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(), .FT_MISO(1'b1), .FT_CS_N(),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

// the memory of the core: 32 KB, an aux port that acks 3 clocks after the request
reg [7:0] mem [0:32767];
wire mem_req, mem_we;
wire [14:0] mem_addr;
wire [7:0] mem_din;
reg mem_ack = 1'b0;
reg [7:0] mem_dout = 8'd0;
reg [1:0] mem_wait = 2'd0;
always @(posedge clk) begin
	mem_ack <= 1'b0;
	if (mem_req && !mem_ack) begin
		if (mem_wait == 2'd2) begin
			mem_wait <= 2'd0;
			mem_ack <= 1'b1;
			if (mem_we) mem[mem_addr] <= mem_din;
			mem_dout <= mem[mem_addr];
		end
		else
			mem_wait <= mem_wait + 2'd1;
	end
end

reg start = 1'b0, core_wr = 1'b0;
reg [14:0] core_addr = 15'd0;
wire busy, mounted, saving, save_error;

kg_bk_ram #(.SLOT(SLOT), .IDLE_CLOCKS(27'd3000), .MAX_CLOCKS(27'd400000), .MOUNT_CLOCKS(27'd3000000),
	.GRACE_CLOCKS(27'd3000), .LINK(2)) bk(
	.clk(clk), .reset(1'b0), .start(start), .size(7'd4), .kind(8'd0),
	.busy(busy), .mounted(mounted), .saving(saving), .save_error(save_error),
	.wr(core_wr), .wr_addr(core_addr),
	.mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_din(mem_din),
	.mem_ack(mem_ack), .mem_dout(mem_dout),
	.img_mounted(8'd0), .img_size(64'd0), .img_data_wr(1'b0), .img_data_addr(9'd0), .img_data(8'd0),
	.img_result_wr(1'b0), .img_result(8'd0), .img_sum(16'd0), .img_flush(img_flush),
	.img_q_wr(), .img_q_di(), .img_q_ack(1'b0),
	.sdc_img_mounted_i(sdc_img_mounted), .sdc_img_size_i(sdc_img_size), .sdc_rd_o(sdc_rd),
	.sdc_wr_o(sdc_wr), .sdc_sector_o(sdc_sector), .sdc_busy_i(sdc_busy), .sdc_done_i(sdc_done),
	.sdc_error_i(sdc_error), .sdc_slot_i(sdc_slot), .sdc_byte_in_strobe_i(sdc_strobe),
	.sdc_byte_addr_i(sdc_addr), .sdc_byte_in_data_i(sdc_in), .sdc_byte_out_data_o(sdc_out),
	.bk_mount(bk_mount), .bk_flushed(bk_flushed), .bk_size(bk_size), .bk_kind(bk_kind),
	.bk_result(bk_result)
);

// ---------------- the mcu ----------------

reg [7:0] tx [0:1023];
reg [7:0] rx [0:1023];

task xbyte(input [7:0] b, output [7:0] r);
	integer i;
	begin
		for (i = 7; i >= 0; i = i - 1) begin
			mosi = b[i];
			#31; sck = 1'b1; r[i] = miso;
			#31; sck = 1'b0;
		end
	end
endtask

task packet(input integer len);
	integer i;
	reg [7:0] r;
	begin
		ss = 1'b0; #31;
		for (i = 0; i < len; i = i + 1) begin
			xbyte(tx[i], r);
			rx[i] = r;
		end
		#31; ss = 1'b1; #1000;
	end
endtask

// the byte i of sector s of the file
function [7:0] pat(input integer s, input integer i);
	pat = i[7:0] + 8'h31 + { 7'd0, i[8] } + s[7:0] * 8'd17;
endfunction

// EVENT: T C Z kind slot arguments x 5: payload m at packet byte m + 2
task event_read(output [7:0] kind, output [7:0] slot, output [31:0] arg, output [7:0] ext);
	integer i;
	begin
		tx[0] = 8'h03; tx[1] = 8'h02;
		for (i = 2; i < 10; i = i + 1) tx[i] = 8'h00;
		packet(10);
		kind = rx[3]; slot = rx[4]; arg = { rx[8], rx[7], rx[6], rx[5] }; ext = rx[9];
	end
endtask

task rdata(input [7:0] slot, input integer s, output [7:0] status);
	integer i;
	reg [15:0] sum;
	begin
		sum = 16'd0;
		tx[0] = 8'h03; tx[1] = 8'h03; tx[2] = slot;
		for (i = 0; i < 512; i = i + 1) begin
			tx[3 + i] = pat(s, i);
			sum = sum + pat(s, i);
		end
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

task flush(input [7:0] slot);
	begin
		tx[0] = 8'h03; tx[1] = 8'h06; tx[2] = slot; packet(3);
	end
endtask

// WDATA: T C slot Z 512 bytes sum lo hi; checks them against the memory sector s
task wdata_check(input integer s);
	integer i;
	reg ok;
	reg [15:0] sum;
	begin
		tx[0] = 8'h03; tx[1] = 8'h04; tx[2] = SLOT;
		for (i = 3; i < 518; i = i + 1) tx[i] = 8'h00;
		packet(518);
		ok = 1'b1; sum = 16'd0;
		for (i = 0; i < 512; i = i + 1) begin
			if (rx[4 + i] !== mem[s * 512 + i]) ok = 1'b0;
			sum = sum + mem[s * 512 + i];
		end
		check("WDATA = the memory sector", ok, 1'b1);
		check("WDATA sum", { rx[517], rx[516] }, sum);
	end
endtask

task img_irq(output bit);
	begin
		tx[0] = 8'h00; tx[1] = 8'h01; tx[2] = 8'h00; tx[3] = 8'h00; tx[4] = 8'h00;
		packet(5);
		bit = rx[4][3];
	end
endtask

// INT for IMG: polled every 20 us, at most 2 ms (the load of a sector into the memory takes ~150 us)
task wait_irq(input [255:0] what);
	integer t;
	reg bit;
	begin
		bit = 1'b0;
		for (t = 0; t < 100 && !bit; t = t + 1) begin
			#20000;
			img_irq(bit);
		end
		check(what, bit, 1'b1);
	end
endtask

// a write of the core: the memory and the dirty mark
task core_write(input [14:0] a, input [7:0] v);
	begin
		mem[a] = v;
		@(posedge clk); core_addr <= a; core_wr <= 1'b1;
		@(posedge clk); core_wr <= 1'b0;
	end
endtask

integer i, s;
reg b, ok;
reg [7:0] kind, slot, st, ext;
reg [31:0] arg;
initial begin
	for (i = 0; i < 32768; i = i + 1) mem[i] = 8'hEE;
	#2000;
	img_irq(b); check("INT low at start", b, 1'b0);

	// ---- start: the mount request ----
	@(posedge clk); start <= 1'b1;
	@(posedge clk); start <= 1'b0;
	#2000;
	check("busy after start", busy, 1'b1);
	img_irq(b); check("INT for the mount", b, 1'b1);
	event_read(kind, slot, arg, ext);
	check("event kind mount", kind, 8'd4);
	check("mount slot", slot, 8'd5);
	check("mount size", arg, 32'd4);
	check("mount kind", ext, 8'd0);
	img_irq(b); check("INT after the mount event", b, 1'b0);

	// MOUNT slot 5: a file of 3 sectors
	tx[0] = 8'h03; tx[1] = 8'h01; tx[2] = SLOT;
	tx[3] = 8'h00; tx[4] = 8'h06; for (i = 5; i < 11; i = i + 1) tx[i] = 8'h00;
	tx[11] = 8'h00;
	packet(12);

	for (s = 0; s < 3; s = s + 1) begin
		wait_irq("load: INT");
		event_read(kind, slot, arg, ext);
		check("load: event kind read", kind, 8'd1);
		check("load: slot", slot, 8'd5);
		check("load: lba", arg, s);
		rdata(SLOT, s, st);
		check("load: taken", st, 8'd0);
		done(SLOT, 8'd1);
	end
	#300000;
	check("busy ends", busy, 1'b0);
	check("mounted", mounted, 1'b1);
	ok = 1'b1;
	for (s = 0; s < 3; s = s + 1)
		for (i = 0; i < 512; i = i + 1)
			if (mem[s * 512 + i] !== pat(s, i)) ok = 1'b0;
	check("the file in the memory", ok, 1'b1);
	check("sector 3 untouched", mem[3 * 512 + 7], 8'hEE);
	img_irq(b); check("INT low after the load", b, 1'b0);

	// ---- a write into sector 1: autosave ----
	core_write(15'h0205, 8'hA5);
	#300000;
	img_irq(b); check("INT for the save", b, 1'b1);
	event_read(kind, slot, arg, ext);
	check("save: event kind write", kind, 8'd2);
	check("save: slot", slot, 8'd5);
	check("save: lba 1", arg, 32'd1);
	wdata_check(1);
	done(SLOT, 8'd1);
	#20000;
	check("no save error", save_error, 1'b0);

	// ---- FLUSH, nothing dirty ----
	flush(SLOT);
	#20000;
	img_irq(b); check("INT for the flush answer", b, 1'b1);
	event_read(kind, slot, arg, ext);
	check("flush: event kind 3", kind, 8'd3);
	check("flush: slot", slot, 8'd5);
	check("flush: result 1", arg, 32'd1);

	// ---- a write into sector 2, FLUSH at once ----
	core_write(15'h0400, 8'h5A);
	flush(SLOT);
	#300000;
	event_read(kind, slot, arg, ext);
	check("flush save: kind write", kind, 8'd2);
	check("flush save: lba 2", arg, 32'd2);
	wdata_check(2);
	done(SLOT, 8'd1);
	#300000;
	event_read(kind, slot, arg, ext);
	check("flush save: answer kind 3", kind, 8'd3);
	check("flush save: result 1", arg, 32'd1);

	// ---- a write that fails, FLUSH: result 2 ----
	core_write(15'h0010, 8'h11);
	flush(SLOT);
	#300000;
	event_read(kind, slot, arg, ext);
	check("fail: kind write", kind, 8'd2);
	check("fail: lba 0", arg, 32'd0);
	wdata_check(0);
	for (i = 0; i < 4; i = i + 1) begin   // DONE 2 = again; RETRIES 3, then the write fails
		done(SLOT, 8'd2);
		#20000;
		if (i < 3) begin
			event_read(kind, slot, arg, ext);
			check("fail: again", kind, 8'd2);
			wdata_check(0);
		end
	end
	#300000;
	event_read(kind, slot, arg, ext);
	check("fail: answer kind 3", kind, 8'd3);
	check("fail: result 2", arg, 32'd2);
	check("save error", save_error, 1'b1);
	// the sector is still dirty: saved again after the answer
	#300000;
	event_read(kind, slot, arg, ext);
	check("again after the error: kind write", kind, 8'd2);
	check("again after the error: lba 0", arg, 32'd0);
	wdata_check(0);
	done(SLOT, 8'd1);

	#300000;
	event_read(kind, slot, arg, ext);
	check("no event at the end", kind, 8'd0);
	img_irq(b); check("INT low at the end", b, 1'b0);

	$display("tb_kg_bk_ram2: %0d errors", errors);
	$finish;
end

// a run that hangs
initial begin
	#200000000;
	$display("ERROR: timeout");
	$display("tb_kg_bk_ram2: %0d errors", errors + 1);
	$finish;
end

endmodule
