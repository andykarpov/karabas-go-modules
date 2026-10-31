`timescale 1ns / 1ps

// kg_mcu_printer: the status request at the start, busy until the first status, a byte and the
// request after it in order, busy until the answer, the request again after RETRY_CLKS without an
// answer, a busy status of the mcu. The transmit port is granted when it asks (tx_full 0) or
// held off (tx_full 1).

module tb_printer;

reg clk = 1'b0;
always #10 clk = ~clk;

reg rx_stb = 1'b0;
reg [7:0] rx_cmd = 8'd0, rx_addr = 8'd0, rx_data = 8'd0;
reg [7:0] prn_data = 8'd0;
reg prn_wr = 1'b0;
reg tx_full = 1'b0;
wire prn_busy, tx_req;
wire [23:0] tx_data;
wire tx_grant = tx_req;

kg_mcu_printer #(.RETRY_CLKS(24'd200)) dut(
	.clk(clk), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
	.prn_data(prn_data), .prn_wr(prn_wr), .prn_busy(prn_busy),
	.tx_req(tx_req), .tx_data(tx_data), .tx_grant(tx_grant), .tx_full(tx_full));

integer errors = 0, nw = 0;
reg [23:0] sent [0:15];
always @(posedge clk) if (tx_grant) begin sent[nw] <= tx_data; nw <= nw + 1; end

task status(input [7:0] ss);
	begin @(negedge clk) begin rx_stb = 1'b1; rx_cmd = 8'h14; rx_addr = 8'h00; rx_data = ss; end
	@(negedge clk) rx_stb = 1'b0; end
endtask
task expect_word(input integer i, input [23:0] w);
	begin if (sent[i] !== w) begin $display("ERROR: word %0d %h, expected %h", i, sent[i], w); errors = errors + 1; end end
endtask
task expect_busy(input b);
	begin if (prn_busy !== b) begin $display("ERROR: busy %b at %0t, expected %b", prn_busy, $time, b); errors = errors + 1; end end
endtask

initial begin
	repeat (5) @(negedge clk);
	if (nw != 1) begin $display("ERROR: %0d words at the start", nw); errors = errors + 1; end
	expect_word(0, 24'h140000);
	expect_busy(1);
	status(8'h00);
	@(negedge clk) expect_busy(0);
	// a byte: DATA, then a request; busy until the answer
	@(negedge clk) begin prn_data = 8'h41; prn_wr = 1'b1; end
	@(negedge clk) prn_wr = 1'b0;
	expect_busy(1);
	repeat (3) @(negedge clk);
	expect_word(1, 24'h130041);
	expect_word(2, 24'h140000);
	if (nw != 3) begin $display("ERROR: %0d words after the byte", nw); errors = errors + 1; end
	expect_busy(1);
	// no answer: the request again after RETRY_CLKS
	repeat (205) @(negedge clk);
	if (nw != 4) begin $display("ERROR: no retry (%0d words)", nw); errors = errors + 1; end
	expect_word(3, 24'h140000);
	// the answer: busy (paper out), then ready
	status(8'h80);
	@(negedge clk) expect_busy(1);
	status(8'h00);
	@(negedge clk) expect_busy(0);
	// a full queue holds the byte back
	tx_full = 1'b1;
	@(negedge clk) begin prn_data = 8'h42; prn_wr = 1'b1; end
	@(negedge clk) prn_wr = 1'b0;
	repeat (5) @(negedge clk);
	if (nw != 4) begin $display("ERROR: a word into a full queue"); errors = errors + 1; end
	tx_full = 1'b0;
	repeat (3) @(negedge clk);
	expect_word(4, 24'h130042);
	expect_word(5, 24'h140000);
	$display("tb_printer: %0d errors", errors);
	$finish;
end

endmodule
