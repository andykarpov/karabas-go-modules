`timescale 1ns / 1ps

/*
 tb_sync.v: kg_sync with W 1 / 3, STAGES 2 / 3 and an INIT other than 0; d changes at random times of
 another clock. q must be INIT for the first STAGES clocks and then the value d had STAGES rising edges of
 clk before (a model of the stages), every clock. Run by run_ctl_sim.sh.
*/
module tb_sync;
reg clk = 0, clk_d = 0;
always #20 clk = ~clk;
always #13.7 clk_d = ~clk_d;
integer errors = 0, checks = 0, n = 0;

reg [2:0] d = 3'b000;
always @(posedge clk_d) d <= $random;

wire q1;
wire [2:0] q2, q3;
kg_sync k1 (.clk(clk), .d(d[0]), .q(q1));
kg_sync #(.W(3), .STAGES(2), .INIT(3'b101)) k2 (.clk(clk), .d(d), .q(q2));
kg_sync #(.W(3), .STAGES(3), .INIT(3'b110)) k3 (.clk(clk), .d(d), .q(q3));

// the model: d at the last three rising edges of clk
reg [2:0] m0, m1, m2;
always @(posedge clk) begin
	m2 <= m1; m1 <= m0; m0 <= d;
	n <= n + 1;
end

task automatic check;
	input [127:0] name;
	input [2:0] got, exp;
	begin
		checks = checks + 1;
		if (got !== exp) begin
			errors = errors + 1;
			if (errors < 10) $display("%t %0s: %b, expected %b", $time, name, got, exp);
		end
	end
endtask

always @(negedge clk) begin
	check("W 1", {2'b00, q1}, n < 2 ? 3'b000 : {2'b00, m1[0]});
	check("W 3 STAGES 2", q2, n < 2 ? 3'b101 : m1);
	check("W 3 STAGES 3", q3, n < 3 ? 3'b110 : m2);
end

initial begin
	#200000;
	$display("tb_sync: %0d checks, %0d errors", checks, errors);
	$finish;
end
endmodule
