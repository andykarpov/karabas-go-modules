`timescale 1ns / 1ps

// pll_reset: a pulse of one clock gives 8 clocks of o_reset; a request held for N clocks keeps o_reset
// high all the time and 7 clocks after it (it fell for one clock in nine). Ends with "tb_pll_reset: N errors".

module tb_pll_reset;

integer errors = 0;
reg clk = 1'b0;
always #5 clk = ~clk;
reg req = 1'b0;
wire o;
pll_reset dut(.clk(clk), .i_reset(req), .o_reset(o));

// o_reset after a request of len clocks: high for len + 7 clocks, then low
task check(input integer len);
	integer i, high;
	begin
		@(negedge clk) req = 1'b1;
		repeat (len) @(negedge clk);
		req = 1'b0;
		high = 0;
		for (i = 0; i < len + 20; i = i + 1) begin
			if (o) high = high + 1;
			@(negedge clk);
		end
		// o rose a clock after the request: len - 1 clocks of it were counted before the loop
		if (high + len - 1 != len + 7) begin
			$display("ERROR: a request of %0d clocks: o_reset %0d clocks after its end, expected 8", len, high);
			errors = errors + 1;
		end
	end
endtask

// o_reset high on every clock while the request is held
always @(negedge clk) if (req && dut.pll_rst_cnt != 0 && !o) begin
	$display("%t ERROR: o_reset low during a request", $time);
	errors = errors + 1;
end

initial begin
	repeat (20) @(negedge clk);
	check(1);
	check(2);
	check(9);
	check(40);
	$display("tb_pll_reset: %0d errors", errors);
	$finish;
end

endmodule
