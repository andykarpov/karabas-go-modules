// kg_ym2149: the AY-3-8910 / YM2149F of the ZX cores, with the ports of ym2149.v (MikeJ / Sorgelig)
// that turbosound.v of tsconf / baseconf / profi instantiates, built on ay38910_silicon.v.
//
// ay38910_silicon.v: a synchronous model of the AY-3-8910 after the "AY-3-8910 Synchronous rev 10"
// schematic of dr.Titus (zx-pk.ru/threads/36422, from the transistor-level reverse engineering of
// deathsoft), by Activator RFG (2026-11-22, no licence given, taken as open). It is checked against
// the transistor-level model of lvd2 / deathsoft (github.com/lvd2/ay-3-8910_reverse_engineered,
// GPL v3) in sim/audio/tb_ay_diff.v. Against ym2149.v: a write of R13 restarts the envelope period
// counter too, the noise LFSR is x^17 + x^14 + 1 (taps 0 and 3), the AY DAC levels are the measured
// ones (DDp), all 16 registers are 0 after RESET (ym2149.v: R7 = FF), in the YM mode a fixed level
// N is 2N+1 of 31 (ym2149.v: {N, N[3]}).
//
//   BDIR BC  Mode
//    0   0   inactive
//    0   1   read value
//    1   0   write value
//    1   1   set address
//   SEL  = 1: the AY clock is CE / 2 (3.5 MHz CE -> 1.75 MHz), 0: CE
//   MODE = 1: AY-3-8910 (16-step envelope, DDp DAC table), 0: YM2149F (32 steps, YM table)

module kg_ym2149
(
	input  wire       CLK,       // global clock (28 MHz)
	input  wire       CE,        // PSG clock enable (3.5 MHz with SEL = 1)
	input  wire       RESET,     // chip reset, active high: all registers 0
	input  wire       BDIR,      // bus direction (0 - read, 1 - write)
	input  wire       BC,        // bus control (BC1; BC2 tied high)
	input  wire [7:0] DI,        // data in
	output wire [7:0] DO,        // data out (FF when not read)
	output reg  [7:0] CHANNEL_A = 8'd0,
	output reg  [7:0] CHANNEL_B = 8'd0,
	output reg  [7:0] CHANNEL_C = 8'd0,

	input  wire       SEL,
	input  wire       MODE,

	output wire [5:0] ACTIVE,

	input  wire [7:0] IOA_in,
	output wire [7:0] IOA_out,

	input  wire [7:0] IOB_in,
	output wire [7:0] IOB_out
);

// SEL = 1 divides CE by 2
reg sel_div = 1'b0;
always @(posedge CLK) begin
	if (RESET)
		sel_div <= 1'b0;
	else if (CE)
		sel_div <= ~sel_div;
end
wire ay_ce_p = CE & (~SEL | sel_div);

wire [7:0] dac_a, dac_b, dac_c;

ay38910_silicon u_ay (
	.clk      (CLK),
	.ce_p     (ay_ce_p),
	.rst      (RESET),

	.bdir     (BDIR),
	.bc2      (1'b1),
	.bc1      (BC),
	.a8       (1'b1),
	.a9_n     (1'b0),
	.test2    (1'b0),

	.da_in    (DI),
	.da_out   (DO),
	.da_oe    (),

	.ym_mode  (~MODE),

	.ioa_in   (IOA_in),
	.ioa_out  (IOA_out),
	.ioa_oe   (),
	.iob_in   (IOB_in),
	.iob_out  (IOB_out),
	.iob_oe   (),

	.test1    (),

	.ch_a_raw (),
	.ch_b_raw (),
	.ch_c_raw (),
	.ch_a_5b  (),
	.ch_b_5b  (),
	.ch_c_5b  (),

	.active   (ACTIVE),
	.ch_a_dac (dac_a),
	.ch_b_dac (dac_b),
	.ch_c_dac (dac_c)
);

// the DAC tables are combinational: registered here for the mixer
always @(posedge CLK) begin
	if (RESET) begin
		CHANNEL_A <= 8'd0;
		CHANNEL_B <= 8'd0;
		CHANNEL_C <= 8'd0;
	end else begin
		CHANNEL_A <= dac_a;
		CHANNEL_B <= dac_b;
		CHANNEL_C <= dac_c;
	end
end

endmodule
