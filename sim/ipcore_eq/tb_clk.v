`timescale 1ps / 1ps

/*
 tb_clk.v: kg_pll / kg_dcm against the coregen clocking wizard cores they replace (alf pll.v and
 pllx5.v, nes nes_clk.v, next pll_midi.vhd; unisim models): every edge of the outputs and LOCKED compared. Run by
 run_ipcore_eq.sh.
*/
module tb_clk;
reg clk50 = 0, clk25 = 0, clk28 = 0;
always #10000 clk50 = ~clk50;
always #20000 clk25 = ~clk25;
always #17857 clk28 = ~clk28;
integer errors = 0, edges = 0;

// alf ipcore_dir/pll.v: 50 MHz pin -> 84.09 / 7.97 / 15.95 / 12.01 MHz
wire [3:0] c_pll; wire c_lock;
pll c1 (.CLK_IN1(clk50), .CLK_OUT1(c_pll[0]), .CLK_OUT2(c_pll[1]), .CLK_OUT3(c_pll[2]), .CLK_OUT4(c_pll[3]), .LOCKED(c_lock));
wire [5:0] k_pll; wire k_lock;
kg_pll #(.CLKIN_PERIOD(20.0), .DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37),
	.CLKOUT0_DIVIDE(11), .CLKOUT1_DIVIDE(116), .CLKOUT2_DIVIDE(58), .CLKOUT3_DIVIDE(77),
	.IBUFG(1), .BUFG_MASK(6'b001111)) k1 (.clk_in(clk50), .rst(1'b0), .clk_out(k_pll), .locked(k_lock));

// alf ipcore_dir/pllx5.v: 25 MHz -> 125 MHz and its inverse
wire c_fx, c_fx180, c_dlock;
pllx5 c2 (.CLK_IN1(clk25), .CLK_OUT1(c_fx), .CLK_OUT2(c_fx180), .LOCKED(c_dlock));
wire k_fx, k_fx180, k_dlock;
kg_dcm #(.CLKIN_PERIOD(40.0), .CLKFX_MULTIPLY(5), .CLKFX_DIVIDE(1)) k2 (.clk_in(clk25), .rst(1'b0),
	.clk_fx(k_fx), .clk_fx180(k_fx180), .clk_0(), .locked(k_dlock));

// nes nes_clk.v: 50 MHz pin -> 21.51 / 25.0 MHz
wire [1:0] c_nes; wire c_nlock;
nes_clk c4 (.CLK_IN1(clk50), .CLK_OUT1(c_nes[0]), .CLK_OUT2(c_nes[1]), .LOCKED(c_nlock));
wire [5:0] k_nes; wire k_nlock;
kg_pll #(.CLKIN_PERIOD(20.0), .DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37), .CLKOUT0_DIVIDE(43), .CLKOUT1_DIVIDE(37),
	.IBUFG(1), .BUFG_MASK(6'b000011)) k4 (.clk_in(clk50), .rst(1'b0), .clk_out(k_nes), .locked(k_nlock));

// next ipcore_dir/pll_midi.vhd: 28 MHz -> 12 MHz (MIDI), no LOCKED. Its DCM_SP is the VHDL unisim
// model, whose edges come up to 2 ps away from the Verilog one of kg_dcm (the 41666.67 ps half
// period rounded): compared 5 ps after every edge of either, from 20 us (both locked)
wire c_midi, k_midi;
pll_midi c3 (.CLK_IN1(clk28), .CLK_OUT1(c_midi));
kg_dcm #(.CLKIN_PERIOD(35.714), .CLKFX_MULTIPLY(3), .CLKFX_DIVIDE(7)) k3 (.clk_in(clk28), .rst(1'b0),
	.clk_fx(k_midi), .clk_fx180(), .clk_0(), .locked());
integer midi_edges = 0;
always @(c_midi or k_midi) begin
	#5;
	if ($time > 20000000) begin
		midi_edges = midi_edges + 1;
		if (c_midi !== k_midi) begin
			errors = errors + 1;
			if (errors < 10) $display("%t midi: coregen %b kg %b", $time, c_midi, k_midi);
		end
	end
end

wire [10:0] c_all = {c_nlock, c_nes, c_dlock, c_fx180, c_fx, c_lock, c_pll};
wire [10:0] k_all = {k_nlock, k_nes[1:0], k_dlock, k_fx180, k_fx, k_lock, k_pll[3:0]};
always @(c_all or k_all) begin
	#1; // both models update in the same time step
	if ($time > 0) begin
		edges = edges + 1;
		if (c_all !== k_all) begin
			errors = errors + 1;
			if (errors < 10) $display("%t coregen %b kg %b", $time, c_all, k_all);
		end
	end
end
initial begin
	#200000000;
	$display("tb_clk: locked pll %b/%b dcm %b/%b, %0d edges, %0d midi edges, %0d errors", c_lock, k_lock,
		c_dlock, k_dlock, edges, midi_edges, errors);
	$finish;
end
endmodule
