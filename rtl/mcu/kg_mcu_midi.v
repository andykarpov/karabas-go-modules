`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_mcu_midi.v

 MIDI IN from a USB MIDI keyboard on the MCU (CMD_MIDI 16, karabas-go-firmware usb/midi_host,
 docs/protocol.md; a decoder on the frame bus of kg_mcu_link). The firmware sends it only to a
 core whose CMD_CAPS answer has bit 4 (ENABLE_MIDI of kg_mcu).
 - CMD_MIDI seq d: a MIDI byte, plain stream without running status (SysEx, F8, FE dropped by
   the firmware): midi_data = d, midi_wr one clock;
 - seq counts the bytes (+1 each, wraps): midi_lost is one clock with the byte after a gap (the
   event queue of the firmware was full). Not after the first byte since reset.
*/

module kg_mcu_midi (
	input wire clk,
	input wire rx_stb,
	input wire [7:0] rx_cmd,
	input wire [7:0] rx_addr,
	input wire [7:0] rx_data,

	output reg [7:0] midi_data = 8'd0,
	output reg midi_wr = 1'b0,
	output reg midi_lost = 1'b0
);

`include "kg_mcu_cmds.vh"

reg [7:0] seq_next = 8'd0;
reg seen = 1'b0;

always @(posedge clk) begin
	midi_wr <= 1'b0;
	midi_lost <= 1'b0;
	if (rx_stb && rx_cmd == CMD_MIDI) begin
		midi_data <= rx_data;
		midi_wr <= 1'b1;
		midi_lost <= seen && rx_addr != seq_next;
		seq_next <= rx_addr + 8'd1;
		seen <= 1'b1;
	end
end

endmodule
