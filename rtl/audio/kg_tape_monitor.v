`timescale 1ns / 1ps
// kg_tape_monitor: the tape input and the tape output of a core heard in its mixer (the OSD switch
// "Tape monitor": 0 off, 1 in, 2 out, 3 both), as a tape recorder with its speaker on would let you hear
// a loading or a saving.
//
// A level held at 1 is not sound: an input with a pullup and no cable reads 1, a ROM leaves MIC at 1
// after a BEEP or a save. Each signal counts only while it has changed in the last HOLD_US (the relaxer
// of the next core, its audio_mixer.v: about 37 ms, 13 Hz at 50 % duty); after that a 1 gives 0 until
// the next edge, so no constant offset is left in the mix. A held 0 gives 0 anyway.
//
// tape_in is asynchronous (a pin, a comparator): two flip-flops here. tape_out is a register of clk.
// sample: LEVEL_IN for a live 1 of the input plus LEVEL_OUT for a live 1 of the output, else 0; a
// register of clk, to be added to the mix of the core. in_on / out_on: the live 1s, before the mode.
// Cost: about 30 LUT, 40 FF.
module kg_tape_monitor #(
	parameter integer CLK_HZ    = 28000000,
	parameter integer HOLD_US   = 37000,
	parameter integer LEVEL_IN  = 4096,
	parameter integer LEVEL_OUT = 2048
) (
	input  wire               clk,
	input  wire [1:0]         mode,
	input  wire               tape_in,
	input  wire               tape_out,
	output wire               in_on,
	output wire               out_on,
	output reg  signed [15:0] sample = 16'sd0
);

// a tick every HOLD_US / 64: a 1 is live for 64 ticks after its edge (the error is one tick, 1.6 %)
// (no $clog2: XST 14.7 does not take it)
function integer bits(input integer n);
	integer k;
	begin bits = 1; for (k = 2; k < n; k = k * 2) bits = bits + 1; end
endfunction
localparam integer TICK = (CLK_HZ / 1000) * (HOLD_US / 64) / 1000;
localparam integer TW = bits(TICK);
localparam [31:0] TICK_LAST32 = TICK - 1, L_IN32 = LEVEL_IN, L_OUT32 = LEVEL_OUT;
localparam [TW - 1:0] TICK_LAST = TICK_LAST32[TW - 1:0];
localparam signed [15:0] L_IN = L_IN32[15:0], L_OUT = L_OUT32[15:0];

reg [TW - 1:0] div = {TW{1'b0}};
reg tick = 1'b0;
always @(posedge clk) begin
	tick <= 1'b0;
	if (div == TICK_LAST) begin
		div <= {TW{1'b0}};
		tick <= 1'b1;
	end else
		div <= div + 1'b1;
end

(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] in_s = 2'b00;
always @(posedge clk) in_s <= {in_s[0], tape_in};
wire in_v = in_s[1];

reg [6:0] in_hold = 7'd0, out_hold = 7'd0;
reg in_q = 1'b0, out_q = 1'b0;
always @(posedge clk) begin
	in_q <= in_v;
	out_q <= tape_out;
	if (in_v != in_q) in_hold <= 7'd0;
	else if (tick && !in_hold[6]) in_hold <= in_hold + 1'b1;
	if (tape_out != out_q) out_hold <= 7'd0;
	else if (tick && !out_hold[6]) out_hold <= out_hold + 1'b1;
end

assign in_on = in_q & ~in_hold[6];
assign out_on = out_q & ~out_hold[6];

always @(posedge clk)
	sample <= ((mode[0] && in_on) ? L_IN : 16'sd0) + ((mode[1] && out_on) ? L_OUT : 16'sd0);

endmodule
