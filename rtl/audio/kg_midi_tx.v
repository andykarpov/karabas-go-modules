`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_midi_tx.v

 A MIDI out port: bytes into a fifo, sent at 31250 baud 8N1 on tx (idle high). For a thru of
 the MIDI IN of kg_mcu (USB keyboard, kg_mcu_midi) to the SAM2695 synth of the boards (MIDI_TX).
 A byte takes 320 us on the line and the firmware sends a note as 3 frames in ~10 us, so a chord
 or a fast controller waits in the fifo: 2^AW bytes, LUT RAM (AW 6: 64 bytes, 20 ms). A byte
 written while it is full is dropped (overflow one clock). No reset: a byte on the line is
 always finished, the receiver would see a broken one otherwise.
*/

module kg_midi_tx #(
	parameter CLK_HZ = 40910000,
	parameter BAUD = 31250,
	parameter AW = 6
) (
	input wire clk,

	input wire [7:0] data,
	input wire wr,
	output reg overflow = 1'b0,

	output reg tx = 1'b1
);

localparam integer DIV = (CLK_HZ + BAUD / 2) / BAUD;
localparam integer CW = 16; // DIV < 65536: clk up to 2 GHz (no $clog2 in the Verilog of XST / ISim)

wire empty, full;
wire [7:0] q;
reg rd = 1'b0;

kg_fifo #(.DW(8), .AW(AW)) u_fifo(
	.clk(clk), .reset(1'b0),
	.wr(wr), .din(data), .full(full),
	.rd(rd), .dout(q), .empty(empty), .count()
);

reg busy = 1'b0, pend = 1'b0, load = 1'b0; // pend: rd seen by the fifo, q comes next clock
reg [8:0] shift = 9'h1FF;  // the data bits and the stop bit, after the start bit on tx
reg [3:0] bits = 4'd0;
reg [CW-1:0] cnt = {CW{1'b0}};

always @(posedge clk) begin
	overflow <= wr && full;
	rd <= 1'b0;
	if (load) begin
		// q is the byte of the rd two clocks before
		load <= 1'b0;
		busy <= 1'b1;
		shift <= { 1'b1, q };
		bits <= 4'd9;
		cnt <= DIV[CW-1:0] - 1'b1;
		tx <= 1'b0; // start bit
	end
	else if (busy) begin
		if (cnt != 0)
			cnt <= cnt - 1'b1;
		else if (bits == 0)
			busy <= 1'b0; // the stop bit has been on the line for a bit time
		else begin
			tx <= shift[0];
			shift <= { 1'b1, shift[8:1] };
			bits <= bits - 1'b1;
			cnt <= DIV[CW-1:0] - 1'b1;
		end
	end
	else if (pend) begin
		pend <= 1'b0;
		load <= 1'b1;
	end
	else if (!empty && !rd) begin
		rd <= 1'b1;
		pend <= 1'b1;
	end
end

endmodule
