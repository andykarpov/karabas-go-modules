`timescale 1ns / 1ps

/*
 The clocks of the HDMI of the Mini boards with two video sources (kg_hdmi_ft): the core (clk_ref) or the
 FT812 (ft_sel, FT_CLK 24...80 MHz). The hdmi_pll.v of the cores menu / tsconf (the same logic), with
 the reference frequency as parameters.

 In the mode of the core clk_ref goes to the 5x DCM. In the FT mode the frequency of FT_CLK (clk) is
 measured (kg_freq_counter) and DCM_CLKGEN is programmed to make it from clk_8 (8 MHz, the clock of the
 FT812 crystal input: 8 x M / D, M 3...10); its output goes to the 5x DCM. The pixel clock is the input of
 the 5x DCM, so its CLKFX is aligned to it.

 Programming (UG382, Dynamic Frequency Synthesis): once for every frequency of the FT mode, also for the
 frequency of the FT mode before when the mode of the core was between (the 5x DCM ran on clk_ref then),
 never twice in a row (a second LoadD started while the first was shifted out made LoadM of it: no signal).
 The 5x DCM is held in reset while DCM_CLKGEN is not locked and 7 clocks more (pll_reset).
*/

module kg_hdmi_ft_pll #(
	parameter integer REF_HZ = 28000000, // clk_ref
	parameter [7:0] REF_MHZ = 8'd28      // freq in the mode of the core
) (
	input wire clk,         // FT_CLK, 24...80 MHz (only measured)
	input wire clk_ref,     // the clock of the core
	input wire clk_ref_pll, // the same clock before its BUFG (the PLL output): the input of the BUFGMUX
	input wire clk_8,       // 8 MHz
	input wire reset,
	input wire ft_sel,      // 1: the FT812 video
	output wire clk_hdmi,   // x5
	output wire clk_hdmi_n, // x5 180 deg
	output wire clk_pix,    // x1
	output wire clk_pix2,   // x1 / 2
	output wire [7:0] freq, // the programmed frequency of the FT mode, MHz (0 in the mode of the core)
	output wire locked,     // the 5x DCM
	output wire o_reset     // the reset of the 5x DCM
);

wire [7:0] hdmi_freq;
kg_freq_counter #(.REF_HZ(REF_HZ), .REF_MHZ(REF_MHZ)) freq_counter(
	.clk_ref(clk_ref),
	.clk_test(clk),
	.sel(ft_sel),
	.freq(hdmi_freq)
);

wire prog_done, locked_dcm;
reg [24:0] prog_data = 25'd0, prog_en = 25'd0;

// a change of the frequency
reg hdmi_reset = 1'b0;
reg [7:0] prev_hdmi_freq = 8'd0;
reg prev_ft_sel = 1'b0;
always @(posedge clk_ref) begin
	hdmi_reset <= 1'b0;
	// back to clk_ref
	if (~ft_sel && prev_ft_sel)
		hdmi_reset <= 1'b1;
	// every FT mode is programmed as a change, also at the frequency of the FT mode before: the 5x DCM
	// ran on clk_ref in between, and nothing else reset it (no signal)
	if (~ft_sel)
		prev_hdmi_freq <= 8'd0;
	// not on the first clock of the FT mode (kg_freq_counter still gives REF_MHZ then: two programmings in
	// a row, LoadM instead of LoadD), not while a sequence is shifted out
	else if (prev_ft_sel && prog_done && ~|prog_en) begin
		if (prev_hdmi_freq != hdmi_freq)
			hdmi_reset <= 1'b1;
		prev_hdmi_freq <= hdmi_freq;
	end
	prev_ft_sel <= ft_sel;
end
assign freq = prev_hdmi_freq;

// M and D of DCM_CLKGEN for hdmi_freq (CLKFX = 8 MHz x M / D)
reg [15:0] fctl; // {M, D}
always @(*) begin
	case (hdmi_freq)
		8'd24: fctl = {8'd3, 8'd1};
		8'd32: fctl = {8'd4, 8'd1};
		8'd40: fctl = {8'd5, 8'd1};
		8'd48: fctl = {8'd6, 8'd1};
		8'd56: fctl = {8'd7, 8'd1};
		8'd64: fctl = {8'd8, 8'd1};
		8'd72: fctl = {8'd9, 8'd1};
		8'd80: fctl = {8'd10, 8'd1};
		default: fctl = {8'd10, 8'd1};
	endcase
end

// UG382 Dynamic Frequency Synthesis, bit 0 first:
//   PROGDATA: 1 0 (LoadD) D-1 [0:7] 0 0, 1 1 (LoadM) M-1 [0:7] 0 0, GO
//   PROGEN:   1 1         1 x 8     0 0, 1 1         1 x 8     0 0, 0
always @(posedge clk_ref) begin
	if (hdmi_reset) begin
		prog_data <= {1'b0, 2'b00, fctl[15:8] - 8'd1, 2'b11, 2'b00, fctl[7:0] - 8'd1, 2'b01};
		prog_en   <= {1'b1, 2'b00, 8'b11111111,       2'b11, 2'b00, 8'b11111111,      2'b11};
	end
	else begin
		prog_en   <= {1'b0, prog_en[24:1]};
		prog_data <= {1'b0, prog_data[24:1]};
	end
end

wire clkgen;
DCM_CLKGEN #(
	.CLKFXDV_DIVIDE(2),
	.CLKFX_DIVIDE(1),
	.CLKFX_MULTIPLY(4),
	.SPREAD_SPECTRUM("NONE"),
	.STARTUP_WAIT("FALSE"),
	.CLKIN_PERIOD(125.0),
	.CLKFX_MD_MAX(0.000)
) dcm_clkgen_inst (
	.CLKIN(clk_8),
	.CLKFX(clkgen),
	.CLKFX180(),
	.CLKFXDV(),
	.PROGCLK(clk_ref),
	.PROGDATA(prog_data[0]),
	.PROGEN(prog_en[0]),
	.PROGDONE(prog_done),
	.FREEZEDCM(1'b0),
	.LOCKED(locked_dcm),
	.STATUS(),
	.RST(reset)
);

// the input of the 5x DCM: clk_ref or DCM_CLKGEN; the select on a net of its own, so that the ucf of
// a core can take it out of the timing analysis
wire clkpllin;
(* KEEP = "TRUE" *) wire mux_sel = ft_sel;
BUFGMUX clk_in_mux(.I0(clk_ref_pll), .I1(clkgen), .O(clkpllin), .S(mux_sel));

wire pll_rst;
pll_reset pll_reset(
	.clk(clk_ref),
	.i_reset(ft_sel ? (~locked_dcm || reset) : (hdmi_reset || reset)),
	.o_reset(pll_rst)
);
assign o_reset = pll_rst;

wire clk0, clkfx, clkfx180, clkdv, clkfbout, lockedx5;
DCM_SP #(
	.CLKDV_DIVIDE(2.000),
	.CLKFX_DIVIDE(1),
	.CLKFX_MULTIPLY(5),
	.CLKIN_DIVIDE_BY_2("FALSE"),
	.CLKIN_PERIOD(13.000),
	.CLKOUT_PHASE_SHIFT("NONE"),
	.CLK_FEEDBACK("1X"),
	.DESKEW_ADJUST("SYSTEM_SYNCHRONOUS"),
	.PHASE_SHIFT(0),
	.STARTUP_WAIT("FALSE")
) dcm_sp_inst (
	.CLKIN(clkpllin),
	.CLKFB(clkfbout),
	.CLK0(clk0),
	.CLK90(),
	.CLK180(),
	.CLK270(),
	.CLK2X(),
	.CLK2X180(),
	.CLKFX(clkfx),
	.CLKFX180(clkfx180),
	.CLKDV(clkdv),
	.PSCLK(1'b0),
	.PSEN(1'b0),
	.PSINCDEC(1'b0),
	.PSDONE(),
	.LOCKED(lockedx5),
	.STATUS(),
	.RST(pll_rst),
	.DSSEN(1'b0)
);

BUFG clkf_buf(.O(clkfbout), .I(clk0));
BUFG clkout1_buf(.O(clk_hdmi), .I(clkfx));
BUFG clkout2_buf(.O(clk_hdmi_n), .I(clkfx180));
// the pixel clock is the input of the 5x DCM, which aligns CLK0 and CLKFX to it (a BUFGMUX of clk_ref and CLK0
// put the DCM into the path of the pixel clock: 4 ns of skew to clk_ref in the mode of the core)
assign clk_pix = clkpllin;
BUFG clkout4_buf(.O(clk_pix2), .I(clkdv));
assign locked = lockedx5;

endmodule
