`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_mcu_link.v

 The SPI link with the MCU (karabas-go-firmware docs/protocol.md, docs/burst_protocol.md), the
 transport part of mcu.vhd: frames of 3 bytes (cmd, addr, data) in both directions on cs_n, and
 bursts on burst_cs_n. The command decoders (kg_mcu_*) sit on its frame bus; those that answer
 put their words on its transmit ports.

 Receive: rx_stb is one clock per frame with rx_cmd / rx_addr / rx_data (they hold until the
 next frame). A burst byte gives one clock of bst_wr with bst_type / bst_addr / bst_data.

 Transmit: every frame shifts out the word taken from the reply queue (512 x 24) after the frame
 before. When the queue is empty, a NOPE word goes in, so the mcu never reads from an empty
 queue. tx_req[n] with tx_data[n*24 +: 24] asks to put a word in; one word goes in per clock,
 the lowest n first, and tx_grant[n] is high in the clock it is taken (combinational, so a
 source can keep its request up until then). A request that is not granted in its clock is not
 kept: one-clock strobes of two sources in the same clock lose the second (as mcu.vhd). tx_full:
 the queue cannot take a word (a source that must not lose one waits for it).
 CMD_CAPS 00 is answered here, before all ports: bursts (bit 0), MCU_BURST_READY driven (bit 1),
 the backup RAM commands CMD_BK_MOUNT / CMD_IMG_FLUSH (bit 3, CAPS_BK: kg_bk_ram), and the highest
 burst sck BURST_MAX_MHZ (0 = the normal link clock).

 The fixes of karabas-go-core-nanomig (its CLAUDE.md has the cases found on hardware):
 - CS_FILTER: cs_n and burst_cs_n go low at once and high only after CS_FILTER clocks high (0 =
   not filtered; a core must not filter them again). A short spike reset the receivers in the
   middle of a frame.
 - the frame slave is not selected during a burst (sck runs for the burst);
 - one reply word per frame, on do_valid of the slave;
 - kg_spi_slave asks for no word in idle.
*/

module kg_mcu_link #(
	parameter BURST_MAX_MHZ = 0,
	parameter CS_FILTER = 3,
	parameter CAPS_BK = 0,          // caps bit 3: the core has kg_bk_ram (CMD_BK_MOUNT, CMD_IMG_FLUSH)
	parameter TX_PORTS = 1
) (
	input wire clk,
	input wire reset,           // empties the reply queue

	input wire sck,
	input wire mosi,
	output wire miso,           // the frame slave
	output wire miso_en,        // the frame slave is selected (the core muxes other slaves)
	input wire cs_n,
	input wire burst_cs_n,
	output wire burst_ready,

	output wire rx_stb,
	output wire [7:0] rx_cmd,
	output wire [7:0] rx_addr,
	output wire [7:0] rx_data,

	output wire bst_wr,
	output wire [7:0] bst_type,
	output wire [31:0] bst_addr,
	output wire [7:0] bst_data,

	input wire [TX_PORTS-1:0] tx_req,
	input wire [TX_PORTS*24-1:0] tx_data,
	output reg [TX_PORTS-1:0] tx_grant,
	output wire tx_full
);

`include "kg_mcu_cmds.vh"

// ---------------- chip selects ----------------

wire cs_n_f, burst_cs_n_f;
generate
	if (CS_FILTER > 0) begin : kg_mcu_link_csf
		reg [CS_FILTER-1:0] cs_sync = {CS_FILTER{1'b1}}, bcs_sync = {CS_FILTER{1'b1}};
		/* verilator lint_off UNUSEDSIGNAL */
		wire [CS_FILTER:0] cs_next = { cs_sync, cs_n }, bcs_next = { bcs_sync, burst_cs_n }; // the top bit drops out
		/* verilator lint_on UNUSEDSIGNAL */
		always @(posedge clk) begin
			cs_sync <= cs_next[CS_FILTER-1:0];
			bcs_sync <= bcs_next[CS_FILTER-1:0];
		end
		assign cs_n_f = cs_n & (&cs_sync);
		assign burst_cs_n_f = burst_cs_n & (&bcs_sync);
	end
	else begin : kg_mcu_link_nocsf
		assign cs_n_f = cs_n;
		assign burst_cs_n_f = burst_cs_n;
	end
endgenerate

// not selected during a burst
wire ssel = cs_n_f | ~burst_cs_n_f;
assign miso_en = ~ssel;

// ---------------- frames ----------------

wire do_valid;
wire [23:0] do_word, q_dout;
reg prev_valid = 1'b0;

kg_spi_slave #(.N(24)) u_spi(
	.clk(clk), .sck(sck), .ssel(ssel), .mosi(mosi), .miso(miso),
	.di(q_dout), .wren(1'b1), .di_req(),
	.do_valid(do_valid), .dout(do_word)
);

// do_valid is two clocks long: a frame is its first
assign rx_stb = do_valid & ~prev_valid;
assign rx_cmd = do_word[23:16];
assign rx_addr = do_word[15:8];
assign rx_data = do_word[7:0];

// ---------------- bursts ----------------

kg_burst_rx u_burst(
	.clk(clk), .sck(sck), .mosi(mosi), .cs_n(burst_cs_n_f),
	.btype(bst_type), .addr(bst_addr), .data(bst_data), .wr(bst_wr), .active()
);

// a burst byte comes every 250 ns at most (32 MHz sck); a core whose consumer is slower puts a
// fifo behind bst_wr and drives its own ready
assign burst_ready = 1'b1;

// ---------------- reply queue ----------------

reg q_rd = 1'b0, q_wr = 1'b0;
reg [23:0] q_din = 24'd0;
wire q_empty;

kg_fifo #(.DW(24), .AW(9)) u_queue(
	.clk(clk), .reset(reset),
	.wr(q_wr), .din(q_din), .full(tx_full),
	.rd(q_rd), .dout(q_dout), .empty(q_empty), .count()
);

// the word for the next frame: one per frame. It is in the slave about 7 clocks after the frame;
// the mcu waits >= 4.5 us before the next one
always @(posedge clk) begin
	prev_valid <= do_valid;
	q_rd <= rx_stb;
end

// CMD_CAPS 00: answered before all ports
localparam [7:0] CAPS = CAPS_BK ? 8'h0B : 8'h03;
localparam [7:0] CAPS_MAX_MHZ = BURST_MAX_MHZ;
reg caps_pend = 1'b0;
wire caps_q = rx_stb && rx_cmd == CMD_CAPS && rx_addr == 8'h00;

integer i;
reg found;
always @(*) begin
	tx_grant = {TX_PORTS{1'b0}};
	found = caps_pend;
	for (i = 0; i < TX_PORTS; i = i + 1)
		if (tx_req[i] && !found) begin
			tx_grant[i] = 1'b1;
			found = 1'b1;
		end
end

integer j;
always @(posedge clk) begin
	q_wr <= 1'b0;
	if (caps_q)
		caps_pend <= 1'b1;
	if (caps_pend) begin
		q_wr <= 1'b1;
		q_din <= { CMD_CAPS, CAPS, CAPS_MAX_MHZ };
		caps_pend <= caps_q; // a query in this clock is answered next
	end
	else if (|tx_req) begin
		q_wr <= 1'b1;
		for (j = 0; j < TX_PORTS; j = j + 1)
			if (tx_grant[j])
				q_din <= tx_data[j*24 +: 24];
	end
	else if (q_empty) begin
		q_wr <= 1'b1;
		q_din <= { CMD_NOPE, 16'h0000 };
	end
end

endmodule
