`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_aux.v

 Target 07 AUX of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.8), on the byte bus of
 kg_l2_link: the LED matrix add-on, the audio peaks of its meters and the debug values of the
 core, read by the mcu when they changed (irq).

   01 MATRIX   Z, control, 32 bitplane bytes: byte 0..7 the red rows of the left matrix, 8..15
               its green, 16..23 / 24..31 the right one, bit n = column n; control: bit 3 meter
               mode, bit 2 brightness set (bits 7..4)
   02 PEAKS    Z, left (2, LE), right (2): the highest peaks since the last read (cleared by it)
   03 DEBUG    Z, addr (2, LE), data (2)
   04 CHANGED  Z, bits: 0 the matrix (an update), 1 new peaks, 2 the debug values; the read of a
               command above clears its bit

 The core keeps the frames of v1 (MATRIX_CMD of kg_mcu: { command, address, data } with a
 one-clock matrix_cmd_wr): 60 CTL (bit 0 clear, bit 1 update, bit 2 brightness, bit 3 meter
 mode), 61 PIXEL (address Y 7..4 X 3..0, color 0 black / 1 red / 2 yellow / 3 green), 62 BITPLAN
 (byte 0..31), 70 / 71 the peaks (high byte in the address, low in the data: audio_peaks.v).
*/

module kg_l2_aux (
	input wire clk,

	input wire sel,
	input wire [7:0] cmd,
	input wire rq,
	input wire [9:0] rq_m,
	output reg [7:0] q,
	output wire irq,

	input wire [23:0] matrix_cmd,
	input wire matrix_cmd_wr,
	input wire [15:0] debug_addr,
	input wire [15:0] debug_data
);

// ---------------- the frames of the core ----------------

// the planes in LUT RAM: the red rows (byte {matrix, y}) and the green rows, a byte of each
// written per clock; a byte not written since a clear reads 0 (valid bits)
reg [7:0] red [0:15];
reg [7:0] grn [0:15];
reg [15:0] red_v = 16'd0, grn_v = 16'd0;
reg [7:0] ctl = 8'd0;
reg [2:0] changed = 3'b000;
reg [15:0] peak_l = 16'd0, peak_r = 16'd0;
reg [7:0] snap_lh = 8'd0;                   // the peaks of the PEAKS packet being read
reg [15:0] snap_r = 16'd0;
reg [15:0] dbg_a = 16'd0, dbg_d = 16'd0;

wire [7:0] f_cmd = matrix_cmd[23:16], f_a = matrix_cmd[15:8], f_d = matrix_cmd[7:0];
wire [15:0] f_peak = { f_a, f_d };
// PIXEL: the byte of its row in both planes of its matrix (byte = matrix * 16 + green * 8 + y)
wire [2:0] px_col = f_a[2:0];
wire px_on_r = f_d[1:0] == 2'd1 || f_d[1:0] == 2'd2;
wire px_on_g = f_d[1:0] == 2'd3 || f_d[1:0] == 2'd2;

// the reads of the mcu (payload 1 of its command): what they clear
wire rd_matrix = sel && rq && cmd == 8'h01 && rq_m == 10'd1;
wire rd_peaks = sel && rq && cmd == 8'h02 && rq_m == 10'd1;
wire rd_debug = sel && rq && cmd == 8'h03 && rq_m == 10'd1;

// PIXEL and BITPLAN: the byte of each plane (read for a pixel: the other bits stay)
wire [3:0] pa = { f_a[3], f_a[6:4] };          // PIXEL: matrix, y
wire [3:0] ba = { f_a[4], f_a[2:0] };          // BITPLAN: matrix, y (bit 3 of the byte: green)
wire [7:0] red_old = red_v[pa] ? red[pa] : 8'd0;
wire [7:0] grn_old = grn_v[pa] ? grn[pa] : 8'd0;
wire [7:0] px_mask = 8'd1 << px_col;
wire px_wr = matrix_cmd_wr && f_cmd == 8'h61;
wire bp_wr = matrix_cmd_wr && f_cmd == 8'h62;
wire [3:0] red_wa = px_wr ? pa : ba;
wire [7:0] red_wd = px_wr ? (px_on_r ? red_old | px_mask : red_old & ~px_mask) : f_d;
wire red_we = px_wr || (bp_wr && !f_a[3]);
wire [7:0] grn_wd = px_wr ? (px_on_g ? grn_old | px_mask : grn_old & ~px_mask) : f_d;
wire grn_we = px_wr || (bp_wr && f_a[3]);
always @(posedge clk) begin
	if (red_we)
		red[red_wa] <= red_wd;
	if (grn_we)
		grn[red_wa] <= grn_wd;
end

always @(posedge clk) begin
	if (rd_matrix) changed[0] <= 1'b0;
	if (rd_peaks) begin
		changed[1] <= 1'b0;
		snap_lh <= peak_l[15:8];
		snap_r <= peak_r;
		peak_l <= 16'd0;
		peak_r <= 16'd0;
	end
	if (rd_debug) changed[2] <= 1'b0;

	if (matrix_cmd_wr)
		case (f_cmd)
			8'h60: begin
				if (f_d[0]) begin
					red_v <= 16'd0;
					grn_v <= 16'd0;
				end
				if (f_d[1] || f_d[2] || f_d[3] != ctl[3])
					changed[0] <= 1'b1;
				ctl[3] <= f_d[3];
				if (f_d[2])
					ctl[7:4] <= f_d[7:4];
				ctl[2] <= ctl[2] | f_d[2];
			end
			8'h61: begin
				red_v[pa] <= 1'b1;
				grn_v[pa] <= 1'b1;
			end
			8'h62:
				if (f_a[3])
					grn_v[ba] <= 1'b1;
				else
					red_v[ba] <= 1'b1;
			8'h70: begin
				if (f_peak > peak_l || rd_peaks) peak_l <= f_peak;
				changed[1] <= 1'b1;
			end
			8'h71: begin
				if (f_peak > peak_r || rd_peaks) peak_r <= f_peak;
				changed[1] <= 1'b1;
			end
			default: ;
		endcase

	if (debug_addr != dbg_a || debug_data != dbg_d) begin
		dbg_a <= debug_addr;
		dbg_d <= debug_data;
		changed[2] <= 1'b1;
	end
	// the brightness flag says "set it": once read with the matrix, it is done
	if (rd_matrix && !(matrix_cmd_wr && f_cmd == 8'h60))
		ctl[2] <= 1'b0;
end

assign irq = |changed;

// ---------------- the answers ----------------

/* verilator lint_off UNUSEDSIGNAL */
wire [9:0] rq_m_2 = rq_m - 10'd2;
/* verilator lint_on UNUSEDSIGNAL */
wire [3:0] qa = { rq_m_2[4], rq_m_2[2:0] };
wire [7:0] plane_q = rq_m_2[3] ? (grn_v[qa] ? grn[qa] : 8'd0) : (red_v[qa] ? red[qa] : 8'd0);

always @(*) begin
	q = 8'h00;
	if (sel)
		case (cmd)
			8'h01:
				if (rq_m == 10'd1)
					q = ctl;
				else if (rq_m >= 10'd2 && rq_m <= 10'd33)
					q = plane_q;
			8'h02:
				case (rq_m)
					10'd1: q = peak_l[7:0];   // the snapshot is taken in this clock
					10'd2: q = snap_lh;
					10'd3: q = snap_r[7:0];
					10'd4: q = snap_r[15:8];
					default: ;
				endcase
			8'h03:
				case (rq_m)
					10'd1: q = dbg_a[7:0];
					10'd2: q = dbg_a[15:8];
					10'd3: q = dbg_d[7:0];
					10'd4: q = dbg_d[15:8];
					default: ;
				endcase
			8'h04:
				if (rq_m == 10'd1)
					q = { 5'd0, changed };
			default: ;
		endcase
end

endmodule
