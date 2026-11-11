`timescale 1ns / 1ps
// tb_hdf_ata.v (iverilog): hdf_ata (SYNC_BUS 0) as device 0 on a model of the sector side of
// img_sdc (index 4: an image of 256 sectors in memory, a byte every 3 clocks, OUT_LATENCY 3).
// The host bus as a CPU cycle: the strobe STB clocks, register / chip select / data held a clock
// after it (hdf_ata acts at the end of the strobe). Checked:
// - IDENTIFY: the sectors of the image (words 60 / 61);
// - READ SECTORS (LBA 5, two sectors), WRITE SECTORS (LBA 7) and its read back;
// - INITIALIZE DEVICE PARAMETERS (8 heads, 32 sectors), then a CHS read (1 / 2 / 3 = LBA 322 % 256);
// - FORMAT TRACK: DRQ for one block, the 256 words taken, done without a write to the image;
// - an unknown command aborts (ERR, ABRT).
// Ends with "tb_hdf_ata: N errors".
module tb_hdf_ata;
parameter STB = 4;
localparam SECTORS = 512;
reg clk = 0;
always #12.5 clk = ~clk;

reg [2:0] a = 0, a_h = 0;
reg cs = 0, cs_h = 0, rd = 0, wr = 0;
reg [15:0] wdata = 0, wdata_h = 0;
wire [15:0] rdata;
reg mnt = 0;
reg sdc_busy = 0, sdc_done = 0, sdc_error = 0, strobe = 0;
reg [8:0] baddr = 0;
reg [7:0] bin = 0;
wire [7:0] bout;
wire [1:0] s_rd, s_wr;
wire [31:0] sector;

hdf_ata #(.DEF_HEADS(5'd16), .DEF_SPT(8'd63), .SYNC_BUS(0)) dut (
	.clk(clk), .reset(1'b0), .ata_reset(1'b0), .dev0_en(1'b1), .dev(), .dev1_here(),
	.a(cs ? a : a_h), .cs_n({ 1'b1, ~(cs | cs_h) }), .rd_n(~rd), .wr_n(~wr), .din(cs ? wdata : wdata_h),
	.dout(rdata), .img_mounted({ 1'b0, mnt }), .img_size(64'd262144), .sdc_rd(s_rd), .sdc_wr(s_wr),
	.sdc_sector(sector), .sdc_busy(sdc_busy), .sdc_done(sdc_done), .sdc_error(sdc_error),
	.sdc_byte_in_strobe(strobe), .sdc_byte_addr(baddr), .sdc_byte_in_data(bin), .sdc_byte_out_data(bout),
	.led()
);
always @(posedge clk) begin a_h <= a; cs_h <= cs; wdata_h <= wdata; end

// the image and the sector side of img_sdc
reg [7:0] img [0:SECTORS * 512 - 1];
integer writes = 0, k, n;
function [7:0] pat(input integer lba, input integer o);
	pat = (o % 2 == 0) ? (lba + o) : (lba ^ o);
endfunction
initial for (k = 0; k < SECTORS * 512; k = k + 1) img[k] = pat(k / 512, k % 512);
always @(posedge clk) begin
	if (s_rd[0] && !sdc_busy) begin
		sdc_busy <= 1;
		for (n = 0; n < 512; n = n + 1) begin
			@(posedge clk) begin strobe <= 1; baddr <= n; bin <= img[sector * 512 + n]; end
			@(posedge clk) strobe <= 0;
			@(posedge clk);
		end
		sdc_busy <= 0; sdc_done <= 1;
		@(posedge clk) sdc_done <= 0;
	end
	else if (s_wr[0] && !sdc_busy) begin
		sdc_busy <= 1;
		for (n = 0; n < 512; n = n + 1) begin
			@(posedge clk) baddr <= n;
			@(posedge clk); @(posedge clk);
			@(posedge clk) img[sector * 512 + n] = bout;
		end
		writes = writes + 1;
		sdc_busy <= 0; sdc_done <= 1;
		@(posedge clk) sdc_done <= 0;
	end
end

integer errors = 0, i, t, w0;
reg [15:0] v;
reg [15:0] w [0:255];

task cyc(input we, input [2:0] r, input [15:0] d, output [15:0] q);
	begin
		@(posedge clk) begin a <= r; cs <= 1; rd <= !we; wr <= we; wdata <= d; end
		repeat (STB - 1) @(posedge clk);
		#1 q = rdata;
		@(posedge clk) begin cs <= 0; rd <= 0; wr <= 0; a <= 3'd5; wdata <= 16'hDEAD; end
	end
endtask
task wreg(input [2:0] r, input [7:0] d); reg [15:0] q; begin cyc(1, r, { 8'h00, d }, q); end endtask
task rreg(input [2:0] r, output [15:0] q); begin cyc(0, r, 16'd0, q); end endtask
task wait_ready(input drq, input want_err);
	begin
		t = 0;
		rreg(7, v);
		while ((v[7] || (drq && !v[3])) && t < 100000) begin rreg(7, v); t = t + 1; end
		if (t == 100000) begin $display("ERROR: timeout, status %h", v); errors = errors + 1; end
		if (v[0] != want_err) begin $display("ERROR: status %h (ERR wanted %0d)", v, want_err); errors = errors + 1; end
	end
endtask
task read_block; begin for (i = 0; i < 256; i = i + 1) rreg(0, w[i]); end endtask
task check_block(input integer lba, input [15:0] x);
	begin
		for (i = 0; i < 256; i = i + 1)
			if (w[i] !== ({ pat(lba, 2 * i + 1), pat(lba, 2 * i) } ^ x)) begin
				if (errors < 10) $display("ERROR: lba %0d word %0d: %h", lba, i, w[i]);
				errors = errors + 1;
			end
	end
endtask
task lba_cmd(input [7:0] cnt, input [7:0] lba, input [7:0] cmd);
	begin wreg(2, cnt); wreg(3, lba); wreg(4, 0); wreg(5, 0); wreg(6, 8'hE0); wreg(7, cmd); end
endtask

initial begin
	repeat (5) @(posedge clk) ;
	@(posedge clk) mnt <= 1;
	@(posedge clk) mnt <= 0;
	wait_ready(0, 0);
	// IDENTIFY
	wreg(6, 8'hA0); wreg(7, 8'hEC); wait_ready(1, 0); read_block;
	if ({ w[61], w[60] } !== SECTORS) begin $display("ERROR: IDENTIFY %0d sectors", { w[61], w[60] }); errors = errors + 1; end
	// READ SECTORS: LBA 5 and 6
	lba_cmd(2, 5, 8'h20);
	wait_ready(1, 0); read_block; check_block(5, 0);
	wait_ready(1, 0); read_block; check_block(6, 0);
	// WRITE SECTORS LBA 7 (inverted), read back
	lba_cmd(1, 7, 8'h30); wait_ready(1, 0);
	for (i = 0; i < 256; i = i + 1) cyc(1, 0, { pat(7, 2 * i + 1), pat(7, 2 * i) } ^ 16'hFFFF, v);
	wait_ready(0, 0);
	lba_cmd(1, 7, 8'h20); wait_ready(1, 0); read_block; check_block(7, 16'hFFFF);
	// INITIALIZE DEVICE PARAMETERS 8 / 32, CHS 1 / 2 / 3 = (1 * 8 + 2) * 32 + 2 = 322
	wreg(2, 32); wreg(6, 8'hA7); wreg(7, 8'h91); wait_ready(0, 0);
	wreg(2, 1); wreg(3, 3); wreg(4, 1); wreg(5, 0); wreg(6, 8'hA2); wreg(7, 8'h20);
	wait_ready(1, 0); read_block; check_block(322, 0);
	// FORMAT TRACK (cylinder 0, head 1, 32 sectors): one block, no write
	w0 = writes;
	wreg(2, 32); wreg(3, 1); wreg(4, 0); wreg(5, 0); wreg(6, 8'hA1); wreg(7, 8'h50);
	wait_ready(1, 0);
	for (i = 0; i < 256; i = i + 1) cyc(1, 0, i, v);
	wait_ready(0, 0);
	if (writes != w0) begin $display("ERROR: FORMAT TRACK wrote the image"); errors = errors + 1; end
	lba_cmd(1, 32, 8'h20); wait_ready(1, 0); read_block; check_block(32, 0);
	// an unknown command: ABRT
	wreg(7, 8'hF0); wait_ready(0, 1); rreg(1, v);
	if (v[7:0] !== 8'h04) begin $display("ERROR: error %h after an unknown command", v); errors = errors + 1; end
	$display("tb_hdf_ata: %0d errors", errors);
	$finish;
end
initial begin #100000000; $display("tb_hdf_ata: hang, 1 errors"); $finish; end
endmodule
