`timescale 1ns / 1ps

// kg_hdmi_ft_pll against hdmi_pll.v of tsconf (ref/tsconf_hdmi_pll.v, the same pll_reset), clocks of
// the primitives from xilinx_models.v. Every clock of clk_ref: freq, o_reset, PROGDATA, PROGEN compared.
// And what it must do (new_dut):
// - DCM_CLKGEN is programmed by UG382 (bad_seq of the model 0), once on every start of the FT mode with a
//   stable FT_CLK, also at the frequency of the FT mode before (the 5x DCM ran on clk_ref in between),
//   with M / D of that frequency; a change of FT_CLK in the FT mode ends with its M / D; the return to the
//   mode of the core programs it once more (hdmi_reset loads prog_data, M / D of the default: harmless, its
//   output is not used then, and the next FT mode programs it again; as in tsconf and menu, kept);
// - in the FT mode the 5x DCM is held in reset while DCM_CLKGEN is not locked (pll_reset: it fell for one
//   clock in nine during a held request);
// - the 5x DCM is locked at the end of every phase.
// Ends with "tb_hdmi_ft_pll: N errors".

module tb_hdmi_ft_pll;

`include "eq_check.vh"

reg clk_ref = 1'b0, clk_8 = 1'b0, ft_clk = 1'b0;
always #17.857 clk_ref = ~clk_ref;
always #62.5 clk_8 = ~clk_8;
real half = 12.5;
always #(half) ft_clk = ~ft_clk;

reg reset = 1'b1, ft_sel = 1'b0;

wire [7:0] old_freq, new_freq;
wire old_rst, new_rst, old_locked, new_locked;
tsconf_hdmi_pll old_dut(.clk(ft_clk), .clk_ref(clk_ref), .clk_ref_pll(clk_ref), .clk_8(clk_8), .reset(reset),
	.vdac2_sel(ft_sel), .clk_hdmi(), .clk_hdmi_n(), .clk_pix(), .clk_pix2(), .freq(old_freq), .locked(old_locked),
	.o_reset(old_rst));
kg_hdmi_ft_pll #(.REF_HZ(28000000), .REF_MHZ(8'd28)) new_dut(.clk(ft_clk), .clk_ref(clk_ref), .clk_ref_pll(clk_ref),
	.clk_8(clk_8), .reset(reset), .ft_sel(ft_sel), .clk_hdmi(), .clk_hdmi_n(), .clk_pix(), .clk_pix2(),
	.freq(new_freq), .locked(new_locked), .o_reset(new_rst));

always @(negedge clk_ref) if (!reset) begin
	eq_check("freq", old_freq, new_freq);
	eq_check("o_reset", old_rst, new_rst);
	eq_check("locked", old_locked, new_locked);
	eq_check("PROGDATA", old_dut.prog_data[0], new_dut.prog_data[0]);
	eq_check("PROGEN", old_dut.prog_en[0], new_dut.prog_en[0]);
end

// the reset of the 5x DCM held while DCM_CLKGEN is unlocked in the FT mode (a clock later)
reg unlocked_r = 1'b0;
integer rst_gaps = 0;
always @(posedge clk_ref) begin
	if (unlocked_r && !new_rst) begin
		if (rst_gaps < 5) $display("%t ERROR: the 5x DCM out of reset while DCM_CLKGEN is unlocked", $time);
		rst_gaps = rst_gaps + 1;
	end
	unlocked_r <= ft_sel && !new_dut.locked_dcm && !reset;
end

integer phase_errors = 0, p0 = 0;
task phase(input [8*20-1:0] name, input sel, input real mhz, input integer ms,
		input integer min_progs, input integer max_progs, input [7:0] m); // m 0: M / D not checked
	integer n;
	begin
		half = 500.0 / mhz;
		ft_sel = sel;
		p0 = new_dut.dcm_clkgen_inst.programs;
		#(ms * 1000000);
		n = new_dut.dcm_clkgen_inst.programs - p0;
		$display("%t %0s: %0d programmings, M %0d D %0d, freq %0d, locked %b", $time, name, n,
			new_dut.dcm_clkgen_inst.m_val + 1, new_dut.dcm_clkgen_inst.d_val + 1, new_freq, new_locked);
		if (n < min_progs || n > max_progs || (n > 0 && m != 0 && (new_dut.dcm_clkgen_inst.m_val != m - 1 ||
				new_dut.dcm_clkgen_inst.d_val != 0)) || !new_locked) begin
			$display("%t ERROR: %0s: expected %0d..%0d programmings with M %0d, locked", $time, name,
				min_progs, max_progs, m);
			phase_errors = phase_errors + 1;
		end
	end
endtask

initial begin
	#1000 reset = 1'b0;
	phase("core", 0, 40.0, 2, 0, 0, 0);
	phase("FT 40", 1, 40.0, 3, 1, 1, 5);
	phase("FT 24 (change)", 1, 24.0, 4, 1, 2, 3);
	phase("core", 0, 24.0, 2, 1, 1, 0);
	phase("FT 24 again", 1, 24.0, 3, 1, 1, 3);
	phase("core", 0, 80.0, 2, 1, 1, 0);
	phase("FT 80", 1, 80.0, 3, 1, 1, 10);
	phase("FT 64 (change)", 1, 64.0, 4, 1, 2, 8);
	phase("core", 0, 72.0, 2, 1, 1, 0);
	phase("FT 72", 1, 72.0, 3, 1, 1, 9);
	errors = errors + phase_errors + rst_gaps + new_dut.dcm_clkgen_inst.bad_seq + old_dut.dcm_clkgen_inst.bad_seq;
	$display("tb_hdmi_ft_pll: bad sequences %0d / old %0d, reset gaps %0d, %0d checks",
		new_dut.dcm_clkgen_inst.bad_seq, old_dut.dcm_clkgen_inst.bad_seq, rst_gaps, checks);
	$display("tb_hdmi_ft_pll: %0d errors", errors);
	$finish;
end

endmodule
