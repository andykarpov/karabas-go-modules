`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_rtc.v

 Target 06 RTC of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.7), on the byte bus of
 kg_l2_link: the clock registers shared with the MCU, as kg_mcu_rtc of v1 (a 256 x 8 RAM the core
 reads, rtc_a -> rtc_do a clock later, and writes; the formats are the firmware's).

   01 SET  first register, values: register first + k = value k (the whole set at the start, the
           time registers in one packet every 500 ms)
   02 GET  Z, count, (register, value) x count: the registers the CPU of the core wrote, a fifo
           of 8; irq while one waits. Not register C, nor D with SKIP_0D (MC146818: flags), nor
           from SEND_LIMIT up (tsconf: F0, its own registers there)

 A write of the core (rtc_cs and !rtc_wr_n for one clock) is not taken while busy (the mcu sets
 the registers then); a byte of SET waits a clock behind a write of the core.

 COALESCE = 1 (default 0: the fifo as above): no write of the core is lost. A write marks its
 register dirty and keeps its value in a pending RAM (the registers below SEND_LIMIT); a scanner
 (one register a clock) moves the dirty registers with their current value into the fifo, a
 register at most once in it. A register written again before the mcu took it is sent once, with
 the last value (several writes in a row = the last one), and again after the GET that took the
 old one. A SET byte of the mcu for a register dirty or in the fifo is not written: the core keeps
 the value it wrote until the mcu has it (the time of the 500 ms packets would undo the write in
 the RAM the core reads). GET is the same packet (at most 8 a read: the firmware takes 8). For a
 core that writes many registers in a burst (the SETUP of Sprinter: ~150 writes in a millisecond);
 costs two bitmaps of SEND_LIMIT bits, a SEND_LIMIT x 8 distributed RAM and the scanner.
*/

module kg_l2_rtc #(
	parameter SKIP_0D = 1,
	parameter SEND_LIMIT = 256,
	parameter COALESCE = 0
) (
	input wire clk,

	input wire sel,
	input wire stb,
	input wire [7:0] cmd,
	input wire [9:0] n,
	input wire [7:0] d,
	input wire rq,
	input wire [9:0] rq_m,
	output reg [7:0] q,
	output wire irq,
	input wire busy,

	input wire [7:0] rtc_a,
	input wire [7:0] rtc_di,
	output wire [7:0] rtc_do,
	input wire rtc_cs,
	input wire rtc_wr_n
);

wire host_wr = rtc_cs && !rtc_wr_n && !busy;
localparam [8:0] LIMIT = SEND_LIMIT;
wire host_send = host_wr && rtc_a != 8'h0C && !(SKIP_0D && rtc_a == 8'h0D) && { 1'b0, rtc_a } < LIMIT;

// ---------------- SET: the registers of the mcu ----------------

reg [7:0] first = 8'd0;
reg [7:0] mcu_a = 8'd0, mcu_d = 8'd0;
reg mcu_req = 1'b0;
reg w = 1'b0;
reg [7:0] wa = 8'd0, wd = 8'd0;

always @(posedge clk) begin
	w <= 1'b0;
	if (sel && stb && cmd == 8'h01) begin
		if (n == 10'd0)
			first <= d;
		else begin
			mcu_a <= first + n[7:0] - 8'd1;
			mcu_d <= d;
			mcu_req <= 1'b1;
		end
	end
	if (host_wr) begin
		w <= 1'b1;
		wa <= rtc_a;
		wd <= rtc_di;
	end
	else if (mcu_req) begin
		w <= !set_hold;
		wa <= mcu_a;
		wd <= mcu_d;
		mcu_req <= 1'b0;
	end
end

kg_sdpram #(.DW(8), .AW(8)) u_ram(
	.clka(clk), .wea(w), .addra(wa), .dina(wd),
	.clkb(clk), .enb(1'b1), .addrb(rtc_a), .doutb(rtc_do)
);

// ---------------- GET: the writes of the core ----------------

reg [15:0] fifo [0:7];
reg [2:0] wp = 3'd0, rp = 3'd0;
reg [3:0] cnt = 4'd0;
reg [7:0] snap = 8'd0;   // the count of the GET packet
assign irq = cnt != 4'd0;

wire [15:0] head = fifo[rp];
wire push;
wire [15:0] push_d;
wire set_hold;   // COALESCE: the register of a SET byte is the core's until the mcu has it

// payload m: 1 = count, 2 + 2k = register k, 3 + 2k = its value
wire get_cmd = sel && cmd == 8'h02;
wire get_data = rq_m >= 10'd2 && ((rq_m - 10'd2) >> 1) < { 2'd0, snap };

always @(*) begin
	q = 8'h00;
	if (get_cmd) begin
		if (rq_m == 10'd1)
			q = { 4'd0, cnt };
		else if (get_data)
			q = rq_m[0] ? head[7:0] : head[15:8];
	end
end

wire pop = get_cmd && rq && get_data && rq_m[0];

generate
	if (COALESCE != 0) begin : rtc_coalesce
		// the registers of the bitmaps: 2^AW >= SEND_LIMIT
		localparam AW = SEND_LIMIT > 128 ? 8 : SEND_LIMIT > 64 ? 7 : SEND_LIMIT > 32 ? 6 :
			SEND_LIMIT > 16 ? 5 : 4;
		localparam NB = 1 << AW;
		localparam integer LAST_I = SEND_LIMIT - 1;
		localparam [AW-1:0] LAST = LAST_I[AW-1:0];
		reg [NB-1:0] dirty = {NB{1'b0}};    // written by the core, not in the fifo yet
		reg [NB-1:0] queued = {NB{1'b0}};   // in the fifo (once at most)
		reg [AW-1:0] ptr = {AW{1'b0}};
		wire [7:0] pend_q;
		/* verilator lint_off UNUSEDSIGNAL */ // the bits of a register >= 2^AW (not sent)
		wire [7:0] head_a = head[15:8];
		wire [7:0] mcu_a8 = mcu_a;
		wire [7:0] rtc_a8 = rtc_a;
		/* verilator lint_on UNUSEDSIGNAL */
		wire [AW-1:0] host_i = rtc_a8[AW-1:0];
		// the scanner takes ptr when it is dirty, not in the fifo, the fifo has room, and the core
		// does not write it in this clock (that write sets dirty again, its value is taken later)
		wire take = dirty[ptr] && !queued[ptr] && cnt != 4'd8 && !(host_send && host_i == ptr);
		assign push = take;
		assign push_d = { { {(8 - AW){1'b0}}, ptr }, pend_q };
		assign set_hold = { 1'b0, mcu_a8 } < LIMIT && (dirty[mcu_a8[AW-1:0]] || queued[mcu_a8[AW-1:0]]);

		kg_dist_sdpram #(.DW(8), .AW(AW)) u_pend(
			.clk(clk), .we(host_send), .a(host_i), .d(rtc_di), .spo(),
			.dpra(ptr), .dpo(pend_q)
		);

		always @(posedge clk)
			ptr <= ptr == LAST ? {AW{1'b0}} : ptr + 1'b1;

		genvar g;
		for (g = 0; g < NB; g = g + 1) begin : bit_g
			localparam [AW-1:0] I = g;
			always @(posedge clk) begin
				// the core's write wins over the scanner's take of the same clock
				if (host_send && host_i == I)
					dirty[g] <= 1'b1;
				else if (take && ptr == I)
					dirty[g] <= 1'b0;
				if (take && ptr == I)
					queued[g] <= 1'b1;
				else if (pop && head_a[AW-1:0] == I)
					queued[g] <= 1'b0;
			end
		end
	end
	else begin : rtc_fifo
		assign push = host_send && cnt != 4'd8; // a ninth write before a read is lost
		assign push_d = { rtc_a, rtc_di };
		assign set_hold = 1'b0;
	end
endgenerate

always @(posedge clk) begin
	if (push) begin
		fifo[wp] <= push_d;
		wp <= wp + 1'b1;
	end
	if (pop)
		rp <= rp + 1'b1;
	cnt <= cnt + (push ? 4'd1 : 4'd0) - (pop ? 4'd1 : 4'd0);
	if (get_cmd && rq && rq_m == 10'd1)
		snap <= { 4'd0, cnt };
end

endmodule
