`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_hid.v

 Target 01 HID of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.2), on the byte bus of
 kg_l2_link:

   01 KBD    8 bytes, the USB boot report: modifiers, 0, 6 key codes. kbd = { key6 .. key1,
             modifiers } (modifiers in bits 7..0), kbd_wr one clock when the report is whole
   02 PS2    (kind, code) x n: kind 0 = a PS/2 set 2 byte, 1 = an XT byte (bit 7 release);
             ps2_wr one clock per pair with ps2_kind / ps2_code
   03 MOUSE  dx, dy, wheel, buttons: ms_wr one clock when the 4 bytes are in
   04 JOY    port, bits 7..0, bits 15..8: joy_l (port 0) / joy_r (port 1), joy_wr one clock
             (bits: 0 connected, 1 up, 2 down, 3 left, 4 right, 5 start, 6 A, 7 B, 8 C, 9 X,
             10 Y, 11 Z, 12 mode)
   06 EVENT  Z, count, then (command, argument) x count: the PS/2 commands of the core to the
             keyboard (cmd_wr with cmd_data = { command, argument }, ED = LEDs, F0 = set); irq
             while one waits. A fifo of 8.
*/

module kg_l2_hid (
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

	output reg [55:0] kbd = 56'd0,
	output reg kbd_wr = 1'b0,
	output reg [7:0] ps2_code = 8'd0,
	output reg ps2_kind = 1'b0,
	output reg ps2_wr = 1'b0,
	output reg [7:0] ms_x = 8'd0,
	output reg [7:0] ms_y = 8'd0,
	output reg [7:0] ms_z = 8'd0,
	output reg [7:0] ms_b = 8'd0,
	output reg ms_wr = 1'b0,
	output reg [15:0] joy_l = 16'd0,
	output reg [15:0] joy_r = 16'd0,
	output reg joy_wr = 1'b0,

	input wire [15:0] cmd_data,
	input wire cmd_wr
);

reg [39:0] kb_keys = 40'd0; // keys 1..5; key 6 comes with the last byte
reg [7:0] kb_mod = 8'd0;
reg kind = 1'b0;
reg [7:0] mx = 8'd0, my = 8'd0, mz = 8'd0;
reg jport = 1'b0;
reg [7:0] jlo = 8'd0;

// ---------------- the commands of the core ----------------

reg [15:0] fifo [0:7];
reg [2:0] wp = 3'd0, rp = 3'd0;
reg [3:0] cnt = 4'd0;
reg [7:0] snap = 8'd0;   // the count of the EVENT packet
assign irq = cnt != 4'd0;

wire [15:0] head = fifo[rp];

// payload m: 1 = count, 2 + 2k = command k, 3 + 2k = argument k
wire ev_cmd = sel && cmd == 8'h06;
wire ev_data = rq_m >= 10'd2 && ((rq_m - 10'd2) >> 1) < { 2'd0, snap };

always @(*) begin
	q = 8'h00;
	if (ev_cmd) begin
		if (rq_m == 10'd1)
			q = { 4'd0, cnt };
		else if (ev_data)
			q = rq_m[0] ? head[7:0] : head[15:8];
	end
end

wire pop = ev_cmd && rq && ev_data && rq_m[0];
wire push = cmd_wr && cnt != 4'd8;

always @(posedge clk) begin
	if (push) begin
		fifo[wp] <= cmd_data;
		wp <= wp + 1'b1;
	end
	if (pop)
		rp <= rp + 1'b1;
	cnt <= cnt + (push ? 4'd1 : 4'd0) - (pop ? 4'd1 : 4'd0);
	if (ev_cmd && rq && rq_m == 10'd1)
		snap <= { 4'd0, cnt };
end

// ---------------- from the mcu ----------------

always @(posedge clk) begin
	kbd_wr <= 1'b0;
	ps2_wr <= 1'b0;
	ms_wr <= 1'b0;
	joy_wr <= 1'b0;

	if (sel && stb)
		case (cmd)
			8'h01:
				case (n)
					10'd0: kb_mod <= d;
					10'd1: ;
					10'd2: kb_keys[7:0] <= d;
					10'd3: kb_keys[15:8] <= d;
					10'd4: kb_keys[23:16] <= d;
					10'd5: kb_keys[31:24] <= d;
					10'd6: kb_keys[39:32] <= d;
					10'd7: begin
						kbd <= { d, kb_keys[39:0], kb_mod };
						kbd_wr <= 1'b1;
					end
					default: ;
				endcase
			8'h02:
				if (!n[0])
					kind <= d[0];
				else begin
					ps2_kind <= kind;
					ps2_code <= d;
					ps2_wr <= 1'b1;
				end
			8'h03:
				case (n)
					10'd0: mx <= d;
					10'd1: my <= d;
					10'd2: mz <= d;
					10'd3: begin
						ms_x <= mx;
						ms_y <= my;
						ms_z <= mz;
						ms_b <= d;
						ms_wr <= 1'b1;
					end
					default: ;
				endcase
			8'h04:
				case (n)
					10'd0: jport <= d[0];
					10'd1: jlo <= d;
					10'd2: begin
						if (jport)
							joy_r <= { d, jlo };
						else
							joy_l <= { d, jlo };
						joy_wr <= 1'b1;
					end
					default: ;
				endcase
			default: ;
		endcase
end

endmodule
