`timescale 1ns / 1ps

// Backup RAM: kg_mcu (ENABLE_IMG, ENABLE_BK) + kg_bk_ram with a model of the firmware (the .sav file
// of karabas-go-firmware storage: CMD_BK_MOUNT, the file mounter, CMD_IMG_FLUSH) on the spi link
// and a model of the memory of the core (an aux port that acks after a few clocks).
// - caps: bit 3;
// - mount 16 sectors: the file goes into the memory, busy until then;
// - writes into two sectors: autosave after the idle time; a lost data frame of the save;
// - flush: the dirty sector, then the answer 01; flush with nothing dirty;
// - writes that never stop: saved after MAX_CLOCKS;
// - a file shorter than the backup RAM: only its sectors are loaded;
// - a failing write: the flush answers 02;
// - no file (size 0 only), no answer to CMD_BK_MOUNT (an old firmware): busy ends, nothing saved,
//   a flush is answered.
// Ends with "tb_bk: N errors".

module tb_bk;

parameter FRAME_GAP = 500;

reg clk = 1'b0;
always #17.65 clk = ~clk;

integer errors = 0;
task err(input [8*80-1:0] what);
	begin
		$display("%t ERROR: %0s", $time, what);
		errors = errors + 1;
	end
endtask

// ---------------- spi link ----------------

reg cs_n = 1'b1, sck = 1'b0, mosi = 1'b0, burst_cs_n = 1'b1;
wire miso;

task spi_byte(input [7:0] tx, output [7:0] rx);
	integer k;
	begin
		for (k = 7; k >= 0; k = k - 1) begin
			mosi = tx[k];
			#31;
			sck = 1'b1;
			rx[k] = miso;
			#31;
			sck = 1'b0;
		end
	end
endtask

reg [7:0] rc, ra, rd;
task frame(input [7:0] c, input [7:0] a, input [7:0] d);
	begin
		cs_n = 1'b0;
		#100;
		spi_byte(c, rc);
		spi_byte(a, ra);
		spi_byte(d, rd);
		#50;
		cs_n = 1'b1;
		#FRAME_GAP;
		handle_reply;
	end
endtask

// ---------------- dut ----------------

wire [7:0] img_mounted, img_data, img_result, img_flush;
wire [15:0] img_sum;
wire [63:0] img_size;
wire img_data_wr, img_result_wr, img_q_wr, img_q_ack;
wire [8:0] img_data_addr;
wire [23:0] img_q_di;

kg_mcu #(.BURST_MAX_MHZ(32), .CS_FILTER(3), .ENABLE_IMG(1), .ENABLE_BK(1)) mcu(
	.UART_TX_MODE(1'b0), .UART_DLM(8'h00), .UART_DLL(8'h00), .UART_DLM_WR(1'b0), .UART_DLL_WR(1'b0),
	.DEBUG_ADDR(16'h0000), .DEBUG_DATA(16'h0000),
	.CLK(clk), .N_RESET(1'b1),
	.MCU_MOSI(mosi), .MCU_MISO(miso), .MCU_SCK(sck), .MCU_SS(cs_n),
	.MCU_SPI_FT_SS(1'b1), .MCU_SPI_SD2_SS(1'b1), .MCU_BURST_CS_N(burst_cs_n),
	.RTC_A(8'h00), .RTC_DI(8'h00), .RTC_CS(1'b0), .RTC_WR_N(1'b1),
	.UART_TX_DATA(8'h00), .UART_TX_WR(1'b0), .FT_MISO(1'b1), .SD2_MISO(1'b1),
	.MATRIX_CMD(24'h000000), .MATRIX_CMD_WR(1'b0),
	.IMG_MOUNTED(img_mounted), .IMG_SIZE(img_size), .IMG_DATA_WR(img_data_wr),
	.IMG_DATA_ADDR(img_data_addr), .IMG_DATA(img_data), .IMG_RESULT_WR(img_result_wr),
	.IMG_RESULT(img_result), .IMG_SUM(img_sum), .IMG_FLUSH(img_flush),
	.IMG_Q_WR(img_q_wr), .IMG_Q_DI(img_q_di), .IMG_Q_ACK(img_q_ack)
);

reg bk_reset = 1'b0, start = 1'b0, wr = 1'b0;
reg [6:0] size = 7'd0;
reg [14:0] wr_addr = 15'd0;
wire busy, mounted, saving, save_error;
wire mem_req, mem_we, mem_ack;
wire [14:0] mem_addr;
wire [7:0] mem_din, mem_dout;

// short times for the simulation (clocks of 35 ns)
kg_bk_ram #(.SLOT(3'd2), .IDLE_CLOCKS(27'd30000), .MAX_CLOCKS(27'd150000), .MOUNT_CLOCKS(27'd200000),
	.GRACE_CLOCKS(27'd20000), .TIMEOUT(24'd300000)) bk(
	.clk(clk), .reset(bk_reset),
	.start(start), .size(size), .kind(8'h00), .busy(busy), .mounted(mounted), .saving(saving),
	.save_error(save_error),
	.wr(wr), .wr_addr(wr_addr),
	.mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_din(mem_din), .mem_ack(mem_ack),
	.mem_dout(mem_dout),
	.img_mounted(img_mounted), .img_size(img_size), .img_data_wr(img_data_wr), .img_data_addr(img_data_addr),
	.img_data(img_data), .img_result_wr(img_result_wr), .img_result(img_result), .img_sum(img_sum),
	.img_flush(img_flush), .img_q_wr(img_q_wr), .img_q_di(img_q_di), .img_q_ack(img_q_ack)
);

// ---------------- memory of the core ----------------
// an aux port: the request is taken after 1..6 clocks, ack one clock with the read byte

reg [7:0] mem [0:32767];
reg [2:0] mwait = 3'd0;
reg ack_r = 1'b0;
reg [7:0] dout_r = 8'd0;
assign mem_ack = ack_r;
assign mem_dout = dout_r;
always @(posedge clk) begin
	ack_r <= 1'b0;
	if (mem_req && !ack_r) begin
		if (mwait == 0) mwait <= 3'd1 + ($random & 3'd3);
		else if (mwait == 1) begin
			mwait <= 0;
			ack_r <= 1'b1;
			if (mem_we) mem[mem_addr] <= mem_din;
			dout_r <= mem[mem_addr];
		end
		else mwait <= mwait - 3'd1;
	end
end

// the core writes a byte of its backup RAM (as the CPU)
task core_write(input [14:0] a, input [7:0] d);
	begin
		@(posedge clk);
		mem[a] = d;
		wr_addr <= a;
		wr <= 1'b1;
		@(posedge clk);
		wr <= 1'b0;
	end
endtask

// ---------------- firmware model ----------------

reg [7:0] file [0:65535];   // the .sav file
integer file_size = 0;      // 0: no file can be made (size 0 mount only)
reg fw_answer_mount = 1;    // 0: a firmware without CMD_BK_MOUNT
reg fw_fail_writes = 0;     // write requests answered with an error
reg drop_data = 0;          // lose a data frame of the next sector write (fpga -> mcu)
reg [31:0] mnt_size = 0;
reg [7:0] mnt_slot = 0, mnt_kind = 0;
reg mount_pending = 0;
reg [31:0] req_lba = 0;
reg [7:0] req_slot = 0, req_op = 0;
reg req_pending = 0;
reg [3:0] lba_mask = 0;
reg [7:0] wr_bank = 0;
reg [7:0] wr_buf [0:511];
integer wr_count = 0;
reg [15:0] wsum_rx = 0;
reg [1:0] wsum_seen = 0;
reg flush_answer = 0;
reg [7:0] flush_result = 0;
integer writes = 0;         // sectors written to the file
reg [63:0] written = 0;     // which ones
reg [7:0] caps = 0;

task handle_reply;
	begin
		case (rc)
			8'h42: begin req_lba[ra*8 +: 8] = rd; if (ra == 0) lba_mask = 4'b0001; else lba_mask[ra[1:0]] = 1'b1; end
			8'h43: begin req_slot = ra; req_op = rd; req_pending = 1; end
			8'h44: if (ra == 8'h10) begin wsum_rx[7:0] = rd; wsum_seen[0] = 1; end
			       else if (ra == 8'h11) begin wsum_rx[15:8] = rd; wsum_seen[1] = 1; end
			       else wr_bank = rd;
			8'h45: if (drop_data && wr_count == 77) drop_data = 0;
			       else begin wr_buf[{wr_bank[0], ra}] = rd; wr_count = wr_count + 1; end
			8'h47: begin flush_answer = 1; flush_result = rd; if (ra != 2) err("flush answer of another slot"); end
			8'h48: case (ra)
			         8'h00, 8'h01, 8'h02, 8'h03: mnt_size[ra*8 +: 8] = rd;
			         8'h10: mnt_slot = rd;
			         8'h80: begin mnt_kind = rd; mount_pending = fw_answer_mount; end
			         default: err("CMD_BK_MOUNT addr");
			       endcase
			8'hF7: caps = ra;
			default: ;
		endcase
	end
endtask

task mount;
	integer i;
	begin
		$display("%t fw: CMD_BK_MOUNT %0d sectors, slot %0d, kind %0d", $time, mnt_size, mnt_slot, mnt_kind);
		mount_pending = 0;
		frame(8'h40, 8'h00, mnt_slot);
		for (i = 0; i < 8; i = i + 1) frame(8'h41, i, 8'h00);
		if (file_size != 0)
			for (i = 0; i < 8; i = i + 1) frame(8'h41, i, (file_size >> (8 * i)) & 8'hFF);
	end
endtask

task serve;
	integer i, n;
	reg [15:0] sum;
	reg [7:0] dummy;
	begin
		req_pending = 0;
		if (lba_mask != 4'b1111) frame(8'h43, req_slot, 8'h02);
		else if (req_op == 1) begin
			lba_mask = 0;
			burst_cs_n = 1'b0;
			#100;
			spi_byte(8'h45, dummy);
			spi_byte(8'h00, dummy); spi_byte(8'h00, dummy); spi_byte(8'h00, dummy); spi_byte(8'h00, dummy);
			sum = 0;
			for (i = 0; i < 512; i = i + 1) begin
				spi_byte(file[req_lba * 512 + i], dummy);
				sum = sum + file[req_lba * 512 + i];
			end
			#100;
			burst_cs_n = 1'b1;
			#500;
			frame(8'h42, 8'h00, sum[7:0]);
			frame(8'h42, 8'h01, sum[15:8]);
			frame(8'h43, req_slot, 8'h01);
		end
		else begin
			lba_mask = 0;
			wr_count = 0;
			wsum_seen = 0;
			n = 0;
			// as img_receive_sector: the data and both sum bytes, or give up
			while ((wr_count < 512 || wsum_seen != 2'b11) && n < 4000) begin frame(8'hFF, 0, 0); n = n + 1; end
			sum = 0;
			for (i = 0; i < 512; i = i + 1) sum = sum + wr_buf[i];
			if (wr_count != 512 || wsum_seen != 2'b11 || sum != wsum_rx || fw_fail_writes) begin
				$display("%t fw: write sector %0d failed (%0d bytes)", $time, req_lba, wr_count);
				frame(8'h43, req_slot, 8'h02);
			end
			else begin
				for (i = 0; i < 512; i = i + 1) file[req_lba * 512 + i] = wr_buf[i];
				writes = writes + 1;
				written[req_lba] = 1'b1;
				$display("%t fw: wrote sector %0d", $time, req_lba);
				frame(8'h43, req_slot, 8'h01);
			end
		end
	end
endtask

// the main loop of the firmware: polls the link and serves what the core asks
reg fw_run = 1;
reg flush_go = 0;
always begin
	#1000;
	while (fw_run) begin
		if (flush_go) begin flush_go = 0; frame(8'h47, 8'h02, 8'h00); end
		else frame(8'hFF, 0, 0);
		if (mount_pending) mount;
		if (req_pending) serve;
	end
end

// CMD_IMG_FLUSH of slot 2, sent by the main loop of the firmware model
task flush_req;
	begin
		flush_answer = 0;
		flush_go = 1;
	end
endtask

task wait_flush_answer(input [7:0] expect);
	integer n;
	begin
		n = 0;
		while (!flush_answer && n < 2000) begin #10000; n = n + 1; end
		if (!flush_answer) err("no flush answer");
		else if (flush_result != expect) begin
			$display("%t ERROR: flush answer %02x, expected %02x", $time, flush_result, expect);
			errors = errors + 1;
		end
	end
endtask

// ---------------- test ----------------

task game(input [6:0] n);
	begin
		@(posedge clk);
		bk_reset <= 1'b1;
		@(posedge clk);
		bk_reset <= 1'b0;
		size <= n;
		start <= 1'b1;
		@(posedge clk);
		start <= 1'b0;
		@(posedge clk);
		if (!busy) err("not busy after start");
		// busy is combinational (start || state): sampled at the clock, as the core does
		while (busy) @(posedge clk);
		$display("%t game: busy over, mounted %0d", $time, mounted);
	end
endtask

task check_mem(input integer from, input integer to, input integer file_from);
	integer i, bad;
	begin
		bad = 0;
		for (i = from; i < to; i = i + 1)
			if (mem[i] !== file[file_from + i - from]) begin
				if (bad < 4) $display("%t ERROR: mem %04x %02x, file %02x", $time, i, mem[i], file[file_from + i - from]);
				bad = bad + 1;
			end
		errors = errors + (bad != 0);
	end
endtask

integer i, w0;
initial begin
	for (i = 0; i < 65536; i = i + 1) file[i] = (i * 7 + (i >> 9) * 13) & 8'hFF;
	for (i = 0; i < 32768; i = i + 1) mem[i] = 8'hEE;
	#2000;
	fw_run = 0;
	#5000;
	frame(8'hF7, 8'h00, 8'h00);
	frame(8'hFF, 8'h00, 8'h00);
	frame(8'hFF, 8'h00, 8'h00);
	if (caps !== 8'h0B) begin $display("ERROR: caps %02x", caps); errors = errors + 1; end
	fw_run = 1;

	// mount 16 sectors (8 KB): the file in the memory
	file_size = 8192;
	game(7'd16);
	if (!mounted) err("not mounted");
	if (mnt_size != 16 || mnt_slot != 2 || mnt_kind != 0) err("CMD_BK_MOUNT fields");
	check_mem(0, 8192, 0);
	if (mem[8192] !== 8'hEE) err("loaded past the size");
	if (writes != 0) err("writes after the load");

	// writes into sectors 3 and 10: autosaved after the idle time, a data frame of the first lost
	drop_data = 1;
	core_write(15'h0605, 8'h11);
	core_write(15'h1400, 8'h22);
	core_write(15'h15FF, 8'h33);
	#500000;
	if (writes != 0) err("saved before the idle time");
	wait (writes >= 2);
	#200000;
	if (written != 64'h0408) begin $display("ERROR: written %h", written); errors = errors + 1; end
	check_mem(0, 8192, 0);

	// flush: the dirty sector at once, then 01
	written = 0;
	w0 = writes;
	core_write(15'h0A00, 8'h44);
	flush_req;
	wait_flush_answer(8'h01);
	if (written != 64'h0020) begin $display("ERROR: flush wrote %h", written); errors = errors + 1; end
	check_mem(0, 8192, 0);
	// nothing dirty: answered at once
	flush_req;
	wait_flush_answer(8'h01);
	if (writes != w0 + 1) err("flush wrote more");

	// writes that never stop (each sooner than the idle time): saved after MAX_CLOCKS
	written = 0;
	for (i = 0; i < 40; i = i + 1) begin
		core_write(15'h0200 + i, i);
		#300000;
	end
	if (written[1] !== 1'b1) err("not saved after MAX_CLOCKS");
	flush_req;
	wait_flush_answer(8'h01);
	check_mem(0, 8192, 0);

	// a failing write: the flush answers 02, save_error
	fw_fail_writes = 1;
	core_write(15'h1000, 8'h55);
	flush_req;
	wait_flush_answer(8'h02);
	if (!save_error) err("no save_error");
	fw_fail_writes = 0;
	flush_req;
	wait_flush_answer(8'h01);

	// a file shorter than the backup RAM (4 KB of 16 KB): its 8 sectors, the rest as it was
	for (i = 0; i < 32768; i = i + 1) mem[i] = 8'hEE;
	for (i = 0; i < 65536; i = i + 1) file[i] = (i * 5 + 3) & 8'hFF;
	file_size = 4096;
	game(7'd32);
	if (!mounted) err("short file: not mounted");
	check_mem(0, 4096, 0);
	if (mem[4096] !== 8'hEE) err("short file: loaded past its end");

	// no file: size 0 only
	file_size = 0;
	writes = 0;
	game(7'd16);
	if (mounted) err("no file: mounted");
	core_write(15'h0000, 8'h66);
	#2000000;
	if (writes != 0) err("no file: saved");
	flush_req;
	wait_flush_answer(8'h01);

	// an old firmware: no answer to CMD_BK_MOUNT
	fw_answer_mount = 0;
	file_size = 8192;
	game(7'd16);
	if (mounted) err("no answer: mounted");
	flush_req;
	wait_flush_answer(8'h01);

	$display("tb_bk: %0d errors", errors);
	$finish;
end

// +tmax=NS: stop there (debugging, with the output so far)
integer tmax;
initial if ($value$plusargs("tmax=%d", tmax)) begin #(tmax); $display("tb_bk: stopped at %0t, state %0d busy %0d", $time, bk.state, busy); $finish; end

initial begin
	repeat (4) #1000000000;
	$display("ERROR: timeout");
	$display("tb_bk: 1 errors");
	$finish;
end

endmodule
