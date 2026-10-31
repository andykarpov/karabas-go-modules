`timescale 1ns / 1ps

/*
 The frequency of FT_CLK for the HDMI of the Mini boards (kg_hdmi_ft_pll): a Verilog port of
 freq_counter.vhd of the cores menu / tsconf (the same registers), REF_HZ / REF_MHZ for both.

 clk_test is divided by 16 and its edges are counted in clk_ref for 1 ms (REF_HZ / 1000 clocks).
 freq (MHz) is the next FT812 pixel clock to the count: 24, 28, 32, 40, 48, 56, 64, 72, 80
 (REF_MHZ below 22 MHz); REF_MHZ while sel is 0 (the video of the core). It changes only when a count differs from the one
 before, or on the first clock of sel (a mode at the frequency of the mode before).
*/

module kg_freq_counter #(
	parameter integer REF_HZ = 28000000, // the frequency of clk_ref
	parameter [7:0] REF_MHZ = 8'd28       // freq while sel is 0
) (
	input wire clk_ref,
	input wire clk_test,
	input wire sel,                       // 1: the FT812 video, clk_test is measured
	output reg [7:0] freq = 8'd0          // MHz
);

localparam integer INTERVAL_I = REF_HZ / 1000;
localparam [15:0] INTERVAL = INTERVAL_I[15:0];
// the limits of the frequencies in counts of clk_test / 16 per ms (75000 / 16, ...)
localparam [15:0] F80 = 16'd4687, F72 = 16'd4375, F64 = 16'd3750, F56 = 16'd3312,
	F48 = 16'd2687, F40 = 16'd2187, F32 = 16'd1875, F28 = 16'd1625, F24 = 16'd1375;

reg [3:0] test = 4'd0;
always @(posedge clk_test)
	test <= test + 4'd1;

// the MSB of the divider into clk_ref
reg [1:0] test_r = 2'b00;
reg prev_test_r = 1'b0;
always @(posedge clk_ref)
	test_r <= {test_r[0], test[3]};

reg [15:0] cnt = 16'd0, measure = 16'd0, count = 16'd0, prev_count = 16'd0;
reg prev_sel = 1'b0;
always @(posedge clk_ref) begin
	if (cnt < INTERVAL)
		cnt <= cnt + 16'd1;
	else
		cnt <= 16'd0;

	prev_test_r <= test_r[1];
	if (cnt == 16'd0) begin
		count <= measure;
		measure <= 16'd0;
	end
	else if (~prev_test_r && test_r[1])
		measure <= measure + 16'd1;

	if (~sel)
		freq <= REF_MHZ;
	else if (prev_count != count || ~prev_sel) begin
		if (count > F80)            freq <= 8'd80;
		else if (count > F72)       freq <= 8'd72;
		else if (count > F64)       freq <= 8'd64;
		else if (count > F56)       freq <= 8'd56;
		else if (count >= F48)      freq <= 8'd48;
		else if (count >= F40)      freq <= 8'd40;
		else if (count >= F32)      freq <= 8'd32;
		else if (count >= F28)      freq <= 8'd28;
		else if (count >= F24)      freq <= 8'd24;
		else                        freq <= REF_MHZ; // no clock or too slow
	end
	prev_count <= count;
	prev_sel <= sel;
end

endmodule
