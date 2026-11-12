`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_port.v

 One port of target 05 PORT of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.6): a byte
 stream each way between the MCU and the core. kg_mcu2 has one of these per port of its PORTS
 mask (0 the USB serial port, 1 the ESP8266, 2 MIDI IN, 3 the USB printer), all on the byte bus
 of kg_l2_link; a packet is for the port of its first payload byte.

   01 STATUS  port, Z, rx free, tx available, config (4): rx free = bytes the out fifo takes now,
              tx available = bytes waiting in the in fifo (both at most 255), config = cfg
   02 PUT     port, bytes: into the out fifo (bytes over its free room are dropped)
   03 GET     port, count, Z, count bytes from the in fifo (00 when it runs out)
   04 PSTAT   port, status: stat = status, stat_wr one clock

 Core side: out_data with out_wr one clock per byte while out_ready (the core takes a byte
 every clock it is ready); in_data with in_wr one clock pushes a byte, in_full says it would be
 dropped. irq while the in fifo has bytes. Both fifos are LUT RAM with the head readable at once
 (the answer of GET is combinational on it).
*/

module kg_l2_port #(
	parameter [7:0] INDEX = 8'd0,
	parameter OUT_AW = 5,   // the out fifo (mcu -> core): 2^OUT_AW bytes
	parameter IN_AW = 5     // the in fifo (core -> mcu)
) (
	input wire clk,
	input wire reset,

	input wire sel,
	input wire stb,
	input wire [7:0] cmd,
	input wire [9:0] n,
	input wire [7:0] d,
	input wire rq,
	input wire [9:0] rq_m,
	output reg [7:0] q,
	output wire irq,

	output reg [7:0] out_data = 8'd0,
	output reg out_wr = 1'b0,
	input wire out_ready,

	input wire [7:0] in_data,
	input wire in_wr,
	output wire in_full,

	input wire [31:0] cfg,
	output reg [7:0] stat = 8'd0,
	output reg stat_wr = 1'b0
);

// ---------------- the packet is for this port ----------------

reg me = 1'b0;
// the port byte comes with the request of payload 2 (STATUS): it counts in its own clock
wire first = sel && stb && n == 10'd0;
wire mine = first ? d == INDEX : (sel && me);
always @(posedge clk)
	if (first)
		me <= d == INDEX;

// GET: the count is payload 1, it comes with the request of payload 3
reg [7:0] get_n = 8'd0;
wire [7:0] get_now = (sel && stb && n == 10'd1) ? d : get_n;
always @(posedge clk)
	if (sel && stb && n == 10'd1)
		get_n <= d;

// ---------------- the out fifo (mcu -> core) ----------------

reg [7:0] omem [0:(1<<OUT_AW)-1];
reg [OUT_AW-1:0] orp = {OUT_AW{1'b0}}, owp = {OUT_AW{1'b0}};
reg [OUT_AW:0] ocnt = {(OUT_AW+1){1'b0}};
wire o_full = ocnt[OUT_AW];
wire o_empty = ocnt == 0;
wire o_wr = mine && stb && cmd == 8'h02 && n != 10'd0 && !o_full;
wire o_rd = out_ready && !o_empty;
wire [OUT_AW:0] o_free = { 1'b1, {OUT_AW{1'b0}} } - ocnt;

always @(posedge clk) begin
	if (o_wr)
		omem[owp] <= d;
	out_wr <= o_rd;
	if (o_rd)
		out_data <= omem[orp];
	if (reset) begin
		orp <= {OUT_AW{1'b0}};
		owp <= {OUT_AW{1'b0}};
		ocnt <= {(OUT_AW+1){1'b0}};
	end
	else begin
		if (o_wr)
			owp <= owp + 1'b1;
		if (o_rd)
			orp <= orp + 1'b1;
		if (o_wr && !o_rd)
			ocnt <= ocnt + 1'b1;
		else if (o_rd && !o_wr)
			ocnt <= ocnt - 1'b1;
	end
end

// ---------------- the in fifo (core -> mcu) ----------------

reg [7:0] imem [0:(1<<IN_AW)-1];
reg [IN_AW-1:0] irp = {IN_AW{1'b0}}, iwp = {IN_AW{1'b0}};
reg [IN_AW:0] icnt = {(IN_AW+1){1'b0}};
assign in_full = icnt[IN_AW];
wire i_empty = icnt == 0;
wire i_wr = in_wr && !in_full;
// GET: payload 3 .. 2 + count, one byte each
wire i_rd = mine && rq && cmd == 8'h03 && rq_m >= 10'd3 && (rq_m - 10'd3) < { 2'd0, get_now } && !i_empty;

always @(posedge clk) begin
	if (i_wr)
		imem[iwp] <= in_data;
	if (reset) begin
		irp <= {IN_AW{1'b0}};
		iwp <= {IN_AW{1'b0}};
		icnt <= {(IN_AW+1){1'b0}};
	end
	else begin
		if (i_wr)
			iwp <= iwp + 1'b1;
		if (i_rd)
			irp <= irp + 1'b1;
		if (i_wr && !i_rd)
			icnt <= icnt + 1'b1;
		else if (i_rd && !i_wr)
			icnt <= icnt - 1'b1;
	end
end

assign irq = !i_empty;
wire [7:0] i_head = imem[irp];

// ---------------- the answers ----------------

// at most 255 (the fifos are up to 2^15)
wire [15:0] o_free16 = { {(15 - OUT_AW){1'b0}}, o_free };
wire [15:0] icnt16 = { {(15 - IN_AW){1'b0}}, icnt };
wire [7:0] free8 = o_free16 > 16'd255 ? 8'd255 : o_free16[7:0];
wire [7:0] avail8 = icnt16 > 16'd255 ? 8'd255 : icnt16[7:0];

always @(*) begin
	q = 8'h00;
	if (mine)
		case (cmd)
			8'h01:
				case (rq_m)
					10'd2: q = free8;
					10'd3: q = avail8;
					10'd4: q = cfg[7:0];
					10'd5: q = cfg[15:8];
					10'd6: q = cfg[23:16];
					10'd7: q = cfg[31:24];
					default: ;
				endcase
			8'h03:
				if (rq_m >= 10'd3 && !i_empty)
					q = i_head;
			default: ;
		endcase
end

always @(posedge clk) begin
	stat_wr <= 1'b0;
	if (mine && stb && cmd == 8'h04 && n == 10'd1) begin
		stat <= d;
		stat_wr <= 1'b1;
	end
end

endmodule
