`timescale 1ns / 1ps

// Simple behavioural models of the clock primitives of kg_hdmi_ft_pll for Icarus Verilog
// (run_hdmi_sim.sh): enough to check the logic around them, not the clocks themselves.
//
// DCM_CLKGEN checks the programming of UG382 (Dynamic Frequency Synthesis): LoadD (PROGEN 1 for 10
// clocks of PROGCLK, PROGDATA 1 0 then D - 1, LSB first), LoadM the same with 1 1, then GO (PROGEN 1
// one clock, PROGDATA 0). Anything else is counted in bad_seq. After GO, PROGDONE is low for 10
// PROGCLK clocks and LOCKED low for LOCK_CLKS (the output then has the programmed M / D: m_val,
// d_val, and programs counts the GOs).

module DCM_CLKGEN #(
	parameter SPREAD_SPECTRUM = "NONE",
	parameter STARTUP_WAIT = "FALSE",
	parameter integer CLKFXDV_DIVIDE = 2,
	parameter integer CLKFX_DIVIDE = 1,
	parameter integer CLKFX_MULTIPLY = 4,
	parameter real CLKFX_MD_MAX = 0.0,
	parameter real CLKIN_PERIOD = 0.0
) (
	output wire CLKFX180,
	output wire CLKFX,
	output wire CLKFXDV,
	output reg LOCKED = 1'b1,
	output reg PROGDONE = 1'b1,
	output wire [2:1] STATUS,
	input wire CLKIN,
	input wire FREEZEDCM,
	input wire PROGCLK,
	input wire PROGDATA,
	input wire PROGEN,
	input wire RST
);
parameter integer LOCK_CLKS = 60;

assign CLKFX = CLKIN;
assign CLKFX180 = ~CLKIN;
assign CLKFXDV = CLKIN;
assign STATUS = 2'b00;

integer programs = 0, bad_seq = 0, nbits = 0, done_cnt = 0, lock_cnt = 0;
reg [9:0] bits = 10'd0;
reg have_d = 1'b0, have_m = 1'b0;
reg [7:0] d_load = 8'd0, m_load = 8'd0;
reg [7:0] d_val = 8'd0, m_val = 8'd0; // M - 1, D - 1 after GO
always @(posedge PROGCLK) begin
	if (PROGEN) begin
		bits = {PROGDATA, bits[9:1]};
		nbits = nbits + 1;
	end
	else if (nbits != 0) begin
		// the end of a command
		if (nbits == 1 && bits[9] == 1'b0) begin // GO
			if (!(have_d && have_m) || !PROGDONE) bad_seq = bad_seq + 1;
			d_val = d_load; m_val = m_load;
			have_d = 1'b0; have_m = 1'b0;
			programs = programs + 1;
			PROGDONE <= 1'b0; done_cnt = 10;
			LOCKED <= 1'b0; lock_cnt = LOCK_CLKS;
		end
		else if (nbits == 10 && bits[1:0] == 2'b01) begin // LoadD: 1 then 0
			if (have_d || have_m || !PROGDONE) bad_seq = bad_seq + 1;
			d_load = bits[9:2]; have_d = 1'b1;
		end
		else if (nbits == 10 && bits[1:0] == 2'b11) begin // LoadM
			if (!have_d || have_m) bad_seq = bad_seq + 1;
			m_load = bits[9:2]; have_m = 1'b1;
		end
		else begin
			bad_seq = bad_seq + 1;
			have_d = 1'b0; have_m = 1'b0;
		end
		nbits = 0;
	end
	if (done_cnt > 0) begin
		done_cnt = done_cnt - 1;
		if (done_cnt == 0) PROGDONE <= 1'b1;
	end
	if (lock_cnt > 0) begin
		lock_cnt = lock_cnt - 1;
		if (lock_cnt == 0) LOCKED <= 1'b1;
	end
end
endmodule

// DCM_SP: CLK0 / CLKFX follow CLKIN; LOCKED 20 clocks of CLKIN after RST.
module DCM_SP #(
	parameter CLKDV_DIVIDE = 2.0,
	parameter CLKFX_DIVIDE = 1,
	parameter CLKFX_MULTIPLY = 4,
	parameter CLKIN_DIVIDE_BY_2 = "FALSE",
	parameter CLKIN_PERIOD = 10.0,
	parameter CLKOUT_PHASE_SHIFT = "NONE",
	parameter CLK_FEEDBACK = "1X",
	parameter DESKEW_ADJUST = "SYSTEM_SYNCHRONOUS",
	parameter PHASE_SHIFT = 0,
	parameter STARTUP_WAIT = "FALSE"
) (
	input wire CLKFB,
	input wire CLKIN,
	input wire DSSEN,
	input wire PSCLK,
	input wire PSEN,
	input wire PSINCDEC,
	input wire RST,
	output wire CLK0,
	output wire CLK180,
	output wire CLK270,
	output wire CLK2X,
	output wire CLK2X180,
	output wire CLK90,
	output wire CLKDV,
	output wire CLKFX,
	output wire CLKFX180,
	output reg LOCKED = 1'b0,
	output wire PSDONE,
	output wire [7:0] STATUS
);
assign CLK0 = CLKIN;
assign CLK180 = ~CLKIN;
assign CLK270 = ~CLKIN;
assign CLK2X = CLKIN;
assign CLK2X180 = ~CLKIN;
assign CLK90 = CLKIN;
assign CLKDV = CLKIN;
assign CLKFX = CLKIN;
assign CLKFX180 = ~CLKIN;
assign PSDONE = 1'b0;
assign STATUS = 8'd0;
integer n = 0;
always @(posedge CLKIN or posedge RST)
	if (RST) begin
		n <= 0;
		LOCKED <= 1'b0;
	end
	else if (n < 20)
		n <= n + 1;
	else
		LOCKED <= 1'b1;
endmodule

module BUFG(output wire O, input wire I);
assign O = I;
endmodule

module BUFGMUX #(parameter CLK_SEL_TYPE = "SYNC") (output wire O, input wire I0, input wire I1, input wire S);
assign O = S ? I1 : I0;
endmodule
