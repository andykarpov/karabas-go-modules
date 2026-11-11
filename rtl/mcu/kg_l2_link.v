`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_link.v

 The transport of MCU link v2 (karabas-go-firmware docs/link_v2.md): one packet per chip select,
 T (target), C (command), then the payload, SPI mode 0, MSB first, 8-bit bytes. The targets
 (kg_l2_sys, kg_l2_hid, kg_l2_load, ...) sit on its byte bus:

   stb        one clock per payload byte (and for the command byte, with start)
   start      the command byte: cmd is valid from here to the end of the packet
   tgt, cmd   the target and the command of the packet
   n          the index of the payload byte (0 = the byte after the command)
   d          the byte
   rq         one clock: the link wants the byte the target answers at payload position rq_m
   q          the answer (combinational on cmd, rq_m and the state of the target; the link
              registers it in the clock of rq). Reading it may advance the target (a fifo).

 Timing: the reply of packet position p goes into the shifter when byte p-1 ends, and the clk
 side sees byte p-2 only then, so q for payload position m may depend on payload bytes up to
 m - 2: a command that answers has one turnaround byte after its last parameter
 (docs/link_v2.md 3). rq for position m comes with the stb of payload byte m - 2 (m = 0 and 1:
 with the target byte and the command byte).

 irq: the pending bits of the targets, bit n = target n; int_out is their or (the INT line,
 active high).

 Chip select: as kg_mcu_link, cs_n goes low at once and high only after CS_FILTER clocks high.
*/

module kg_l2_link #(
	parameter CS_FILTER = 3
) (
	input wire clk,

	input wire sck,
	input wire mosi,
	output wire miso,
	output wire miso_en,     // selected: the core muxes the other slaves of the bus
	input wire cs_n,

	output reg stb = 1'b0,
	output reg start = 1'b0,
	output reg [7:0] tgt = 8'hFF,
	output reg [7:0] cmd = 8'h00,
	output reg [9:0] n = 10'd0,
	output reg [7:0] d = 8'h00,
	output reg rq = 1'b0,
	output reg [9:0] rq_m = 10'd0,
	input wire [7:0] q,

	input wire [7:0] irq,
	output reg int_out = 1'b0
);

// ---------------- chip select ----------------

wire cs_n_f;
generate
	if (CS_FILTER > 0) begin : kg_l2_csf
		reg [CS_FILTER-1:0] cs_sync = {CS_FILTER{1'b1}};
		/* verilator lint_off UNUSEDSIGNAL */
		wire [CS_FILTER:0] cs_next = { cs_sync, cs_n };
		/* verilator lint_on UNUSEDSIGNAL */
		always @(posedge clk)
			cs_sync <= cs_next[CS_FILTER-1:0];
		assign cs_n_f = cs_n & (&cs_sync);
	end
	else begin : kg_l2_nocsf
		assign cs_n_f = cs_n;
	end
endgenerate

assign miso_en = ~cs_n_f;

// ---------------- bytes ----------------

reg [7:0] di = 8'h00;
reg wren = 1'b0;
wire do_valid;
wire [7:0] dout;

/* verilator lint_off PINCONNECTEMPTY */
kg_spi_slave #(.N(8), .PREFETCH(2)) u_spi(
	.clk(clk), .sck(sck), .ssel(cs_n_f), .mosi(mosi), .miso(miso),
	.di(di), .wren(wren), .di_req(),
	.do_valid(do_valid), .dout(dout)
);
/* verilator lint_on PINCONNECTEMPTY */

// the chip select in this clock: a packet ends when it has been high for 8 clocks, so the last
// byte (do_valid comes ~4 clocks after its last bit) is always taken first
reg [1:0] cs_s = 2'b11;
reg [3:0] high = 4'd0;
/* verilator lint_off SYNCASYNCNET */
always @(posedge clk) begin
	cs_s <= { cs_s[0], cs_n_f }; // a synchroniser: the shifter takes it as its async reset
	if (!cs_s[1])
		high <= 4'd0;
	else if (!high[3])
		high <= high + 1'b1;
end
/* verilator lint_on SYNCASYNCNET */
wire idle = high[3];

// do_valid of kg_spi_slave can be two clocks long: a byte is its first
reg valid_d = 1'b0;
always @(posedge clk)
	valid_d <= do_valid;
wire byte_in = do_valid & ~valid_d;

reg [10:0] pos = 11'd0; // the next byte of the packet: 0 target, 1 command, 2.. payload

always @(posedge clk) begin
	stb <= 1'b0;
	start <= 1'b0;
	rq <= 1'b0;
	wren <= 1'b0;
	int_out <= |irq;

	if (idle) begin
		pos <= 11'd0;
		tgt <= 8'hFF;
		// the reply of position 1: nothing (the shifter needs a word for every byte)
		if (pos != 11'd0) begin
			di <= 8'h00;
			wren <= 1'b1;
		end
	end
	else if (byte_in) begin
		if (pos != 11'h7FF)
			pos <= pos + 1'b1;
		if (pos == 11'd0) begin
			tgt <= dout;
			// the reply of position 2 (payload 0): the command is not known yet
			di <= 8'h00;
			wren <= 1'b1;
		end
		else begin
			if (pos == 11'd1) begin
				cmd <= dout;
				start <= 1'b1;
			end
			else begin
				d <= dout;
				n <= pos[9:0] - 10'd2;
				stb <= 1'b1;
			end
			// ask for the reply of payload position pos (packet position pos + 2)
			rq <= 1'b1;
			rq_m <= pos[9:0];
		end
	end

	// the reply asked in the clock before
	if (rq) begin
		di <= q;
		wren <= 1'b1;
	end
end

endmodule
