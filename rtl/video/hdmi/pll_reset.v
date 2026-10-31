`timescale 1ns / 1ps

module pll_reset (
	input wire clk,
	input wire i_reset,
	output wire o_reset
);

// o_reset is high from the clock after i_reset until 7 clocks after its end (8 clocks for a one clock pulse).
reg [3:0] pll_rst_cnt = 4'd0;
always @(posedge clk)
begin
	if (i_reset) begin
		pll_rst_cnt <= 4'b1000;
	end
	// karabas: else: the count ran on while i_reset was held (the later assignment wins), 8..15, 0, 8..,
	// so o_reset fell for one clock in nine during a long reset request (~locked_dcm in hdmi_pll with
	// DCM_CLKGEN, the reset over its programming). A one clock pulse gives the same o_reset as before,
	// a longer request is no longer cut short.
	else if (pll_rst_cnt > 0) pll_rst_cnt <= pll_rst_cnt+1;
end

assign o_reset = pll_rst_cnt[3];

endmodule
