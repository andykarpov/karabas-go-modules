`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_rpc.v

 Target 08 RPC of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.9): calls of the core to the
 firmware through a mailbox, and events of the firmware to the core. The MCU is the SPI master, so
 a call is a request in a buffer here: the core writes it and calls (irq), the MCU reads it, does it
 and writes the response back. One call at a time, payloads up to 512 bytes, a 16-bit sum (the
 bytes from the id to the end of the payload added) on every request, response and event.

 Link side, payload positions (m), Z = the turnaround byte:
   01 HELLO   fw version, Z, core version, max payload (2), services (2)   enables the irq
   02 STATUS  Z, flags, request length (2)
              flags: bit 0 a request waits for its response, bit 1 the event slot is free,
              bit 2 enabled (HELLO came)
   03 REQ     Z, id, service, function, length (2), payload, sum (2)
              the read of the sum ends the irq of this request (seen); the request stays until its
              response (STATUS bit 0), it can be read again
   04 RESP    id, status, length (2), payload, sum (2), Z, 0 taken / 1 refused
              refused: a bad sum, another id, no request waiting, length over 512
   05 EVENT   service, code, length (2), payload, sum (2), Z, 0 taken / 1 refused
              refused: the slot is not free (STATUS bit 1), a bad sum, length over 512
 irq: a request not yet seen, after HELLO.

 Core side (clk): a byte bus over one block RAM of 2 KB (one clock of read latency):
   000..1FF  W/R  the payload of the request
   200..3FF  R    the payload of the response
   400..5FF  R    the payload of the event
   600 W id, 601 W service, 602 W function, 603 / 604 W length lo / hi
   605 W     call (any value): the request is complete; the response flag drops
   608 R     flags: bit 0 busy (a call waits for its response), bit 1 the response is in,
             bit 2 an event is in, bit 3 enabled
   609 R     response status, 60A / 60B R response length, 60C R response id
   610 R     event service, 611 R event code, 612 / 613 R event length
   614 W     event done (any value): the slot is free again
   618 R     the RPC version of the firmware (HELLO)
*/

module kg_l2_rpc #(
	parameter [7:0] VERSION = 8'd1,
	parameter [15:0] SERVICES = 16'h0000   // the services the core uses (bit n = service n)
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

	input wire [10:0] cpu_a,
	input wire cpu_we,
	input wire [7:0] cpu_wd,
	output wire [7:0] cpu_rd
);

localparam [10:0] REQ_BASE = 11'h000, RESP_BASE = 11'h200, EVT_BASE = 11'h400;

// ---------------- state ----------------

reg enabled = 1'b0;
reg [7:0] fw_ver = 8'd0;
reg busy = 1'b0, seen = 1'b0, resp_in = 1'b0, evt_in = 1'b0;
reg [7:0] r_id = 8'd0, r_svc = 8'd0, r_fn = 8'd0;
reg [9:0] r_len = 10'd0;
reg [7:0] p_id = 8'd0, p_status = 8'd0;
reg [9:0] p_len = 10'd0;
reg [7:0] e_svc = 8'd0, e_code = 8'd0;
reg [9:0] e_len = 10'd0;

assign irq = enabled & busy & ~seen;

// ---------------- the RAM ----------------

reg [10:0] la = 11'd0;       // the link port address
reg l_we = 1'b0;
reg [7:0] l_wd = 8'd0;
wire [7:0] l_rd;
wire cpu_ram_we = cpu_we && cpu_a[10:9] == 2'b00;   // the CPU writes the request only
wire [7:0] c_rd;
kg_tdpram #(.DW(8), .AW(11)) u_ram(
	.clka(clk), .ena(1'b1), .wea(l_we), .addra(la), .dina(l_wd), .douta(l_rd),
	.clkb(clk), .enb(1'b1), .web(cpu_ram_we), .addrb(cpu_a), .dinb(cpu_wd), .doutb(c_rd)
);

// ---------------- link side ----------------

// a 16-bit sum of the bytes of a packet: what went out (REQ) or came in (RESP, EVENT)
reg [15:0] sum = 16'd0;
reg [7:0] sum_rx_lo = 8'd0;              // the low byte of the received sum (the high one is d)
reg [7:0] h_id = 8'd0, h_st = 8'd0;   // RESP: id and status / EVENT: service and code
reg [9:0] h_len = 10'd0;
reg slot_ok = 1'b0;                     // EVENT: the slot was free at its start

wire [9:0] req_end = 10'd6 + r_len;     // REQ: the position of sum lo
wire [9:0] in_end = 10'd4 + h_len;      // RESP / EVENT: the position of sum lo
wire len_ok = h_len <= 10'd512;
// the received sum: the ack is asked with the stb of its high byte (d), in the same clock
wire [15:0] rx_sum = { d, sum_rx_lo };

// the answers (combinational on rq_m; the RAM byte was addressed at the rq before)
always @(*) begin
	q = 8'h00;
	if (sel)
		case (cmd)
			8'h01:
				case (rq_m)
					10'd2: q = VERSION;
					10'd3: q = 8'h00;           // 512 = 0x0200
					10'd4: q = 8'h02;
					10'd5: q = SERVICES[7:0];
					10'd6: q = SERVICES[15:8];
					default: ;
				endcase
			8'h02:
				case (rq_m)
					10'd1: q = { 5'd0, enabled, ~evt_in, busy & ~resp_in };
					10'd2: q = r_len[7:0];
					10'd3: q = { 6'd0, r_len[9:8] };
					default: ;
				endcase
			8'h03:
				if (rq_m == 10'd1) q = r_id;
				else if (rq_m == 10'd2) q = r_svc;
				else if (rq_m == 10'd3) q = r_fn;
				else if (rq_m == 10'd4) q = r_len[7:0];
				else if (rq_m == 10'd5) q = { 6'd0, r_len[9:8] };
				else if (rq_m >= 10'd6 && rq_m < req_end) q = l_rd;
				else if (rq_m == req_end) q = sum[7:0];
				else if (rq_m == req_end + 10'd1) q = sum[15:8];
			8'h04:
				if (rq_m == in_end + 10'd3)
					q = (busy && !resp_in && h_id == r_id && len_ok && rx_sum == sum) ? 8'h00 : 8'h01;
			8'h05:
				if (rq_m == in_end + 10'd3)
					q = (slot_ok && len_ok && rx_sum == sum) ? 8'h00 : 8'h01;
			default: ;
		endcase
end

always @(posedge clk) begin
	l_we <= 1'b0;
	if (reset) begin
		enabled <= 1'b0;
		busy <= 1'b0;
		seen <= 1'b0;
		resp_in <= 1'b0;
		evt_in <= 1'b0;
	end

	// the link reads: the sum of REQ, the next RAM byte, the commits of RESP / EVENT
	if (sel && rq) begin
		if (cmd == 8'h03) begin
			// position 0 (Z) is never asked: the sum starts with the id
			if (rq_m == 10'd1) sum <= { 8'd0, q };
			else if (rq_m < req_end) sum <= sum + { 8'd0, q };
			if (rq_m == req_end + 10'd1) seen <= 1'b1;
			// the RAM byte for the next position
			la <= REQ_BASE + { 1'b0, rq_m - 10'd5 };
		end
		if (cmd == 8'h04 && rq_m == in_end + 10'd3 && q == 8'h00) begin
			busy <= 1'b0;
			resp_in <= 1'b1;
			p_id <= h_id;
			p_status <= h_st;
			p_len <= h_len;
		end
		if (cmd == 8'h05 && rq_m == in_end + 10'd3 && q == 8'h00) begin
			evt_in <= 1'b1;
			e_svc <= h_id;
			e_code <= h_st;
			e_len <= h_len;
		end
	end

	// the link writes
	if (sel && stb)
		case (cmd)
			8'h01:
				if (n == 10'd0) begin
					fw_ver <= d;
					enabled <= 1'b1;
				end
			8'h04, 8'h05: begin
				if (n == 10'd0) begin
					h_id <= d;
					sum <= { 8'd0, d };
					slot_ok <= ~evt_in;
				end else begin
					if (n == 10'd1) h_st <= d;
					if (n == 10'd2) h_len[7:0] <= d;
					if (n == 10'd3) h_len[9:8] <= d[1:0];
					if (n < in_end) sum <= sum + { 8'd0, d };
					if (n == in_end) sum_rx_lo <= d;
				end
				// the payload into its buffer (the response only for a waiting call, the event only
				// into a free slot, so that what the CPU reads is never overwritten)
				if (n >= 10'd4 && n < in_end && n < 10'd516 &&
					(cmd == 8'h04 ? (busy && !resp_in) : slot_ok)) begin
					la <= (cmd == 8'h04 ? RESP_BASE : EVT_BASE) + { 1'b0, n - 10'd4 };
					l_wd <= d;
					l_we <= 1'b1;
				end
			end
			default: ;
		endcase

	// the CPU
	if (cpu_we)
		case (cpu_a)
			11'h600: r_id <= cpu_wd;
			11'h601: r_svc <= cpu_wd;
			11'h602: r_fn <= cpu_wd;
			11'h603: r_len[7:0] <= cpu_wd;
			11'h604: r_len[9:8] <= cpu_wd[1:0];
			11'h605: begin
				busy <= 1'b1;
				seen <= 1'b0;
				resp_in <= 1'b0;
			end
			11'h614: evt_in <= 1'b0;
			default: ;
		endcase
end

// ---------------- core side reads ----------------

reg [7:0] reg_rd = 8'd0;
reg a_reg = 1'b0;
always @(posedge clk) begin
	a_reg <= cpu_a[10:9] == 2'b11;
	case (cpu_a)
		11'h608: reg_rd <= { 4'd0, enabled, evt_in, resp_in, busy };
		11'h609: reg_rd <= p_status;
		11'h60A: reg_rd <= p_len[7:0];
		11'h60B: reg_rd <= { 6'd0, p_len[9:8] };
		11'h60C: reg_rd <= p_id;
		11'h610: reg_rd <= e_svc;
		11'h611: reg_rd <= e_code;
		11'h612: reg_rd <= e_len[7:0];
		11'h613: reg_rd <= { 6'd0, e_len[9:8] };
		11'h618: reg_rd <= fw_ver;
		default: reg_rd <= 8'd0;
	endcase
end
assign cpu_rd = a_reg ? reg_rd : c_rd;

endmodule
