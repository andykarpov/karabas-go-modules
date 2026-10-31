`timescale 1ns / 1ps

// kg_midi_tx.v, iverilog: the bytes written (a run that fills the fifo, then single ones) are
// decoded on tx with a 31250 baud receiver model sampling the middle of each bit: start bit low,
// 8 data bits LSB first, stop bit high, the bit time; a byte written while the fifo is full is
// dropped with overflow. Ends with "tb_midi_tx: N errors".
module tb_midi_tx;

localparam CLK_HZ = 40910000;
localparam DIV = (CLK_HZ + 31250 / 2) / 31250;
localparam real T = 1.0e9 / CLK_HZ;  // ns
localparam real BIT = T * DIV;

reg clk = 1'b0;
always #(T / 2) clk = ~clk;

reg [7:0] data = 8'h00;
reg wr = 1'b0;
wire tx, overflow;
kg_midi_tx #(.CLK_HZ(CLK_HZ), .AW(3)) dut(.clk(clk), .data(data), .wr(wr),
	.overflow(overflow), .tx(tx));

integer errors = 0;
reg [7:0] expect_q [0:63];
integer exp_n = 0, got_n = 0, ovf_n = 0;
always @(posedge clk) if (overflow) ovf_n = ovf_n + 1;

// receiver model
reg [7:0] b;
integer i;
real t0;
initial begin
	forever begin
		@(negedge tx);
		t0 = $realtime;
		#(BIT / 2);
		if (tx !== 1'b0) begin $display("%t ERROR: start bit", $time); errors = errors + 1; end
		for (i = 0; i < 8; i = i + 1) begin
			#(BIT);
			b[i] = tx;
		end
		#(BIT);
		if (tx !== 1'b1) begin $display("%t ERROR: stop bit", $time); errors = errors + 1; end
		if (got_n >= exp_n || b !== expect_q[got_n]) begin
			$display("%t ERROR: byte %0d is %h, expected %h", $time, got_n, b, expect_q[got_n]);
			errors = errors + 1;
		end
		got_n = got_n + 1;
	end
end

task put(input [7:0] d, input ok);
	begin
		@(negedge clk);
		data = d; wr = 1'b1;
		@(negedge clk);
		wr = 1'b0;
		if (ok) begin expect_q[exp_n] = d; exp_n = exp_n + 1; end
	end
endtask

integer k, o;
initial begin
	#1000;
	if (tx !== 1'b1) begin $display("ERROR: tx idle"); errors = errors + 1; end
	// a run: one byte goes out at once, 8 wait in the fifo, the 10th is dropped
	for (k = 0; k < 9; k = k + 1) put(8'h90 + k, 1);
	o = ovf_n;
	put(8'hEE, 0);
	@(negedge clk);
	if (ovf_n != o + 1) begin $display("ERROR: overflow not shown"); errors = errors + 1; end
	wait (got_n == exp_n);
	#(BIT * 3);
	// single bytes, line idle between them
	put(8'h00, 1);
	put(8'hFF, 1);
	wait (got_n == exp_n);
	#(BIT * 2);
	put(8'hA5, 1);
	wait (got_n == exp_n);
	#(BIT * 2);
	if (tx !== 1'b1) begin $display("ERROR: tx not idle at the end"); errors = errors + 1; end
	if (got_n != 12) begin $display("ERROR: %0d bytes received", got_n); errors = errors + 1; end
	$display("tb_midi_tx: %0d errors", errors);
	$finish;
end

initial begin
	#50000000;
	$display("ERROR: timeout");
	$display("tb_midi_tx: 1 errors");
	$finish;
end

endmodule
