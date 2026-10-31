`timescale 1ns / 1ps

// freq_counter.vhd of tsconf (28 MHz) and of menu (40 MHz) against kg_freq_counter with their
// parameters: a test clock of random frequencies (those of the FT812, 15..85 MHz, now and then stopped), sel switched
// at random; freq compared at every clock of the reference. Ends with "tb_eq_freq_counter: N errors".

module tb_eq_freq_counter;

`include "eq_check.vh"

reg clk28 = 1'b0, clk40 = 1'b0, clk_test = 1'b0;
always #17.857 clk28 = ~clk28;
always #12.5 clk40 = ~clk40;

real half = 12.5; // half a period of clk_test, ns
reg run = 1'b1;
always begin
	#(half);
	if (run) clk_test = ~clk_test;
end

reg sel = 1'b0;
wire [7:0] old_t, new_t, old_m, new_m;

freq_counter_tsconf old_tsconf(.i_clk_ref(clk28), .i_clk_test(clk_test), .i_vdac2_sel(sel), .i_reset(1'b0), .o_freq(old_t));
kg_freq_counter #(.REF_HZ(28000000), .REF_MHZ(8'd28)) new_tsconf(.clk_ref(clk28), .clk_test(clk_test), .sel(sel), .freq(new_t));
freq_counter_menu old_menu(.i_clk_ref(clk40), .i_clk_test(clk_test), .i_vdac2_sel(sel), .i_reset(1'b0), .o_freq(old_m));
kg_freq_counter #(.REF_HZ(40000000), .REF_MHZ(8'd40)) new_menu(.clk_ref(clk40), .clk_test(clk_test), .sel(sel), .freq(new_m));

always @(negedge clk28) eq_check("freq tsconf", old_t, new_t);
always @(negedge clk40) eq_check("freq menu", old_m, new_m);

// how often each frequency was seen (that the test covers them)
integer seen [0:255];
integer k;
initial for (k = 0; k < 256; k = k + 1) seen[k] = 0;
always @(negedge clk28) if (sel) seen[new_t] = seen[new_t] + 1;

integer seed = 7, i;
reg [31:0] r;
initial begin
	for (i = 0; i < 40; i = i + 1) begin
		r = $random(seed);
		run = (r[3:0] != 0);
		case (r[19:16])
		0: half = 500.0 / 24.0;  1: half = 500.0 / 28.0;  2: half = 500.0 / 32.0;
		3: half = 500.0 / 40.0;  4: half = 500.0 / 48.0;  5: half = 500.0 / 56.0;
		6: half = 500.0 / 64.0;  7: half = 500.0 / 72.0;  8: half = 500.0 / 80.0;
		default: half = 1000.0 / (2.0 * (15 + r[11:4] % 71)); // 15..85 MHz
		endcase
		if (r[14:12] < 3) sel = ~sel;
		#(400000 + (r[31:20] % 1200) * 1000); // 0.4..1.6 ms
	end
	$display("tb_eq_freq_counter: freq seen 24:%0d 28:%0d 32:%0d 40:%0d 48:%0d 56:%0d 64:%0d 72:%0d 80:%0d",
		seen[24], seen[28], seen[32], seen[40], seen[48], seen[56], seen[64], seen[72], seen[80]);
	$display("tb_eq_freq_counter: %0d checks", checks);
	$display("tb_eq_freq_counter: %0d errors", errors);
	$finish;
end

endmodule
