`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_link.v

 The transport of MCU link v2 (karabas-go-firmware docs/link_v2.md): one packet per chip select,
 T (target), C (command), then the payload, SPI mode 0, MSB first, 8-bit bytes. The targets
 (kg_l2_sys, kg_l2_hid, kg_l2_load, ...) sit on its byte bus:

   stb        one clock per payload byte
   start      one clock with the command byte: cmd is valid from here to the end of the packet
   tgt, cmd   the target and the command of the packet
   n          the index of the payload byte (0 = the byte after the command)
   d          the byte
   rq         one clock: the link wants the byte the target answers at payload position rq_m
   q          the answer (combinational on cmd, rq_m and the state of the target; the link
              registers it in the clock of rq). Reading it may advance the target (a fifo).
 All of the bus is combinational in the clock the byte arrives in (stb, rq, the command byte),
 the targets register what they take.

 Timing: the reply of packet position p goes into the shifter when byte p-1 ends, and the clk
 side sees byte p-2 only then, so q for payload position m may depend on payload bytes up to
 m - 2: a command that answers has one turnaround byte after its last parameter
 (docs/link_v2.md 3). rq for position m comes with the stb of payload byte m - 2 (m = 0 and 1:
 with the target byte and the command byte).

 irq: the pending bits of the targets, bit n = target n; int_out is their or (the INT line,
 active high).

 Chip select: as kg_mcu_link, cs_n goes low at once and high only after CS_FILTER clocks high.
 Clocks: a byte crosses into clk in 3 clocks after the falling edge that ends it, its answer is
 needed ~7 sck periods later: f_clk > 3.5 / (5.5 / f_sck) or so; 28 MHz with 32 MHz sck has margin
 (tb_kg_mcu2). No upper limit: until 2026-11-13 the toggle came at the rising edge of bit 7 and a
 clk over ~4 x f_sck rewrote di before its load (bk at 65 MHz with 16 MHz sck: reads one byte early).
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

	output wire stb,
	output wire start,
	output reg [7:0] tgt = 8'hFF,
	output wire [7:0] cmd,
	output wire [9:0] n,
	output wire [7:0] d,
	output wire rq,
	output wire [9:0] rq_m,
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

reg [7:0] di = 8'h00; // the answer for the next byte

// ---------------- sck domain ----------------
//
// Receive: bits on the rising edge, a whole byte into byte_hold (it holds for the next 8 sck
// periods). Transmit: the falling edge after the last bit of a byte loads di (the answer for the
// next byte) and toggles byte_tgl, the other falling edges shift. The clk side sees the byte by
// that toggle, so it writes di only after the load: no upper limit of clk against sck.

/* verilator lint_off SYNCASYNCNET */
reg [2:0] bitcnt = 3'd0;
always @(posedge sck or posedge cs_n_f)
	if (cs_n_f)
		bitcnt <= 3'd0;
	else
		bitcnt <= bitcnt + 3'd1;

reg [7:0] txsh = 8'h00;
reg first = 1'b1; // no byte of the packet ended yet
always @(negedge sck or posedge cs_n_f)
	if (cs_n_f) begin
		txsh <= 8'h00;
		first <= 1'b1;
	end
	else if (bitcnt == 3'd0 && !first)
		txsh <= di;
	else begin
		txsh <= { txsh[6:0], 1'b0 };
		first <= 1'b0;
	end

// the end of a byte for the clk side: toggled at the same falling edge that loads di, so the clk
// side (which writes the next answer into di when it sees the byte) can never change di before
// that load, however fast clk is against sck (it toggled at the rising edge of bit 7 before: a clk
// over ~4 x sck wrote di within the half period and the answer of the next position went out)
reg byte_tgl = 1'b0;
always @(negedge sck)
	if (!cs_n_f && bitcnt == 3'd0 && !first)
		byte_tgl <= ~byte_tgl;
/* verilator lint_on SYNCASYNCNET */
assign miso = txsh[7];

reg [6:0] shreg = 7'd0;
reg [7:0] byte_hold = 8'd0;
always @(posedge sck)
	if (!cs_n_f) begin
		shreg <= { shreg[5:0], mosi };
		if (bitcnt == 3'd7)
			byte_hold <= { shreg, mosi };
	end

// ---------------- clk domain ----------------

reg [2:0] tgl_s = 3'd0;
always @(posedge clk)
	tgl_s <= { tgl_s[1:0], byte_tgl };
wire byte_in = tgl_s[2] != tgl_s[1];

// the chip select: a packet ends when it has been high for 8 clocks, after its last byte
reg [1:0] cs_s = 2'b11;
reg [3:0] high = 4'd0;
always @(posedge clk) begin
	cs_s <= { cs_s[0], cs_n_f };
	if (!cs_s[1])
		high <= 4'd0;
	else if (!high[3])
		high <= high + 1'b1;
end
wire idle = high[3];

reg [10:0] pos = 11'd0; // the next byte of the packet: 0 target, 1 command, 2.. payload
reg [7:0] cmd_r = 8'h00;

// the byte bus: combinational in the clock of the byte (the targets register it)
assign start = byte_in && pos == 11'd1;
assign cmd = start ? byte_hold : cmd_r;
assign stb = byte_in && pos >= 11'd2;
assign n = pos[9:0] - 10'd2;
assign d = byte_hold;
// the answer for packet position pos + 2 = payload position pos
assign rq = byte_in && pos != 11'd0;
assign rq_m = pos[9:0];

always @(posedge clk) begin
	int_out <= |irq;
	if (byte_in) begin
		if (pos != 11'h7FF)
			pos <= pos + 1'b1;
		if (pos == 11'd0)
			tgt <= byte_hold;
		if (start)
			cmd_r <= byte_hold;
		// the answer: nothing for payload position 0 (the command is not in yet)
		di <= (pos == 11'd0) ? 8'h00 : q;
	end
	else if (idle) begin
		pos <= 11'd0;
		tgt <= 8'hFF;
		di <= 8'h00;
	end
end

endmodule
