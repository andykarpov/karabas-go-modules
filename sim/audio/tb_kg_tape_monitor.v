`timescale 1ns / 1ps
// tb_kg_tape_monitor: kg_tape_monitor at 28 MHz with HOLD_US = 6400 (a tick every 100 us, short runs):
// the four modes, a tone (1 kHz) passes as LEVEL_IN / LEVEL_OUT / their sum, a 1 held after the tone
// goes to 0 after HOLD_US (+- a tick), a held 0 gives 0, the next edge brings it back; the input is two
// clocks late (its synchroniser). Prints "tb_kg_tape_monitor: 0 errors".
module tb_kg_tape_monitor;
localparam integer HOLD = 6400;
reg clk = 1'b0;
always #17.857 clk = ~clk;                 // 28 MHz
reg [1:0] mode = 2'd0;
reg tin = 1'b0, tout = 1'b0;
wire in_on, out_on;
wire signed [15:0] sample;
kg_tape_monitor #(.CLK_HZ(28000000), .HOLD_US(HOLD), .LEVEL_IN(4096), .LEVEL_OUT(2048)) dut (
	.clk(clk), .mode(mode), .tape_in(tin), .tape_out(tout), .in_on(in_on), .out_on(out_on), .sample(sample));

integer errors = 0;
task expect(input [8*32-1:0] what, input signed [15:0] exp);
	begin
		if (sample !== exp) begin
			errors = errors + 1;
			$display("tb_kg_tape_monitor: %0s at %0t: sample %0d, expected %0d", what, $time, sample, exp);
		end
	end
endtask

// a tone on both inputs for ms milliseconds, checked in the middle of each half period
task tone(input integer ms, input signed [15:0] hi);
	integer k;
	begin
		for (k = 0; k < ms * 2; k = k + 1) begin
			tin = !tin; tout = !tout;
			#250000; expect("tone", (tin && tout) ? hi : 16'sd0);
			#250000;
		end
	end
endtask

integer t0, t1, m;
initial begin
	#1000;
	for (m = 0; m < 4; m = m + 1) begin
		mode = m;
		tin = 1'b0; tout = 1'b0;
		#20000000;                          // 20 ms of 0
		expect("held 0", 16'sd0);
		tone(10, (m == 0) ? 16'sd0 : (m == 1) ? 16'sd4096 : (m == 2) ? 16'sd2048 : 16'sd6144);
		// the tone ends with both at 0; one more edge to 1 and hold it
		tin = 1'b1; tout = 1'b1;
		t0 = $time;
		#1000;
		expect("held 1, at once", (m == 0) ? 16'sd0 : (m == 1) ? 16'sd4096 : (m == 2) ? 16'sd2048 : 16'sd6144);
		wait (!in_on);
		t1 = $time;
		if (t1 - t0 < (HOLD - 200) * 1000 || t1 - t0 > (HOLD + 200) * 1000) begin
			errors = errors + 1;
			$display("tb_kg_tape_monitor: mode %0d: a held 1 lasted %0d us, expected %0d", m, (t1 - t0) / 1000, HOLD);
		end
		#1000;
		expect("held 1, relaxed", 16'sd0);
		#20000000;
		expect("held 1, later", 16'sd0);
		// a new edge
		tin = 1'b0; tout = 1'b0; #100000; tin = 1'b1; tout = 1'b1; #1000;
		expect("edge after relax", (m == 0) ? 16'sd0 : (m == 1) ? 16'sd4096 : (m == 2) ? 16'sd2048 : 16'sd6144);
	end
	// the input synchroniser: 2 clocks, + 1 for the register of the sample
	mode = 2'd1; tin = 1'b0; tout = 1'b0; #20000000;
	@(negedge clk); tin = 1'b1;
	repeat (3) @(posedge clk);
	#1;
	if (sample !== 16'sd0) begin errors = errors + 1; $display("tb_kg_tape_monitor: input faster than its synchroniser"); end
	@(posedge clk); #1;
	if (sample !== 16'sd4096) begin errors = errors + 1; $display("tb_kg_tape_monitor: input not there 4 clocks after its edge"); end
	$display("tb_kg_tape_monitor: %0d errors", errors);
	$finish;
end
endmodule
