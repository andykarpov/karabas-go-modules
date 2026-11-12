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
*/

module kg_l2_rtc #(
	parameter SKIP_0D = 1,
	parameter SEND_LIMIT = 256
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
		w <= 1'b1;
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
wire push = host_send && cnt != 4'd8; // a ninth write before a read is lost

always @(posedge clk) begin
	if (push) begin
		fifo[wp] <= { rtc_a, rtc_di };
		wp <= wp + 1'b1;
	end
	if (pop)
		rp <= rp + 1'b1;
	cnt <= cnt + (push ? 4'd1 : 4'd0) - (pop ? 4'd1 : 4'd0);
	if (get_cmd && rq && rq_m == 10'd1)
		snap <= { 4'd0, cnt };
end

endmodule
