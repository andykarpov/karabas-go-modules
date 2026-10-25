`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_sync.v

 Synchroniser of W static or slow signals into the clock clk: STAGES flip-flops in a row (2 or more), each bit
 on its own, so a vector that changes is only seen whole once it held for STAGES clocks (use kg_async_fifo or a
 toggle handshake for data that must cross as a word). q starts at INIT.
 For the settings of the mcu that cross into the pixel or serialiser clock of HDMI (DVI_ONLY of kg_mcu, the
 audio enable made from it): a select of the TMDS encoders that comes from the clk_sys of kg_mcu reaches the
 5x clock of the serialisers through logic with the phase of the two clocks (clk_sys 21.51, pixel 25.0 MHz:
 0.2 ns in the nes core) and fails the timing; from a register of the pixel clock it is a path like the
 encoded words.
 Timing: the paths into the first stage come from another clock: bound them with FROM-TO DATAPATHONLY (one
 period of clk) or TIG them. The stages have ASYNC_REG (kept next to each other, no logic moved into them)
 and SHREG_EXTRACT NO (flip-flops, not a shift register LUT).
*/

module kg_sync #(
	parameter W = 1,
	parameter STAGES = 2,
	parameter [W-1:0] INIT = 0
) (
	input wire clk,
	input wire [W-1:0] d,
	output wire [W-1:0] q
);

// stage n is s[n*W +: W]; no shift register LUT (SRL) for the stages, they must be flip-flops
(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [W*STAGES-1:0] s = {STAGES{INIT}};

always @(posedge clk)
	s <= {s[W*(STAGES-1)-1:0], d};

assign q = s[W*STAGES-1 -: W];

endmodule
