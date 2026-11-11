`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_sys.v

 Target 00 SYS of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.1), on the byte bus of
 kg_l2_link. Payload positions (m), Z = the turnaround byte:

   00 STATUS       Z, 'K', 'G', 2, caps lo, caps hi, osd width / 8, osd height / 8, ports
   01 IRQ          ack, Z, pending (as it was before the ack; the ack clears SYS causes)
   02 IRQ_SRC      Z, causes: bit 0 coldboot, bit 1 reload request (reading clears bit 0)
   03 SETVAL       (index, value) x n: sw_wr one clock with sw_index / sw_value per pair
   04 HW_SETUP     key, value...: byte k is key + k: 00 board, 01 dvi only, 10..17 core build,
                   18..1F firmware build (character 0 in bits 63..56)
   05 INIT         1 = start (busy), 0 = done
   06 SPI_CONTROL  bit 0 FT812 SPI, 1 FT812 video, 4 FT812 reset
   07 BTN          button, state
   08 RELOAD       Z, core id (reading clears the request)

 coldboot is set after the configuration of the fpga and while reset is high (the link of the
 core restarted), so the firmware sees a core that reloaded itself.
*/

module kg_l2_sys #(
	parameter [15:0] CAPS = 16'h0000,
	parameter [7:0] OSD_W8 = 8'd0,
	parameter [7:0] OSD_H8 = 8'd0,
	parameter [7:0] PORTS = 8'h00
) (
	input wire clk,
	input wire reset,

	input wire sel,          // the packet is for this target
	input wire stb,
	input wire [7:0] cmd,
	input wire [9:0] n,
	input wire [7:0] d,
	input wire rq,
	input wire [9:0] rq_m,
	output reg [7:0] q,

	input wire [7:0] pending, // all targets
	output wire irq,

	output reg sw_wr = 1'b0,
	output reg [7:0] sw_index = 8'd0,
	output reg [7:0] sw_value = 8'd0,

	output reg [7:0] hw_id = 8'd0,
	output reg dvi_only = 1'b0,
	output reg [63:0] core_build = 64'd0,
	output reg [63:0] fw_build = 64'd0,
	output reg busy = 1'b1,
	output reg ft_spi_on = 1'b0,
	output reg ft_vga_on = 1'b0,
	output reg ft_reset = 1'b0,
	output reg [1:0] btns = 2'b00,

	input wire reload_req,   // a rising edge asks the mcu to load core reload_core
	input wire [7:0] reload_core
);

reg coldboot = 1'b1;
reg reload = 1'b0, reload_prev = 1'b0;
reg [7:0] key = 8'd0;
reg [7:0] idx = 8'd0;

assign irq = coldboot | reload;

wire [7:0] causes = { 6'd0, reload, coldboot };

// the answers
always @(*) begin
	q = 8'h00;
	if (sel)
		case (cmd)
			8'h00:
				case (rq_m)
					10'd1: q = "K";
					10'd2: q = "G";
					10'd3: q = 8'd2;
					10'd4: q = CAPS[7:0];
					10'd5: q = CAPS[15:8];
					10'd6: q = OSD_W8;
					10'd7: q = OSD_H8;
					10'd8: q = PORTS;
					default: ;
				endcase
			8'h01: if (rq_m == 10'd2) q = pending;
			8'h02: if (rq_m == 10'd1) q = causes;
			8'h08: if (rq_m == 10'd1) q = reload_core;
			default: ;
		endcase
end

wire [7:0] hk = key + n[7:0] - 8'd1; // the key of value byte n (n >= 1)

always @(posedge clk) begin
	sw_wr <= 1'b0;
	reload_prev <= reload_req;
	if (reload_req && !reload_prev)
		reload <= 1'b1;
	if (reset)
		coldboot <= 1'b1;

	if (sel && rq) begin
		if (cmd == 8'h02 && rq_m == 10'd1)
			coldboot <= 1'b0;
		if (cmd == 8'h08 && rq_m == 10'd1)
			reload <= 1'b0;
	end

	if (sel && stb)
		case (cmd)
			8'h01: if (n == 10'd0 && d[0]) coldboot <= 1'b0;
			8'h03:
				if (!n[0])
					idx <= d;
				else begin
					sw_index <= idx;
					sw_value <= d;
					sw_wr <= 1'b1;
				end
			8'h04:
				if (n == 10'd0)
					key <= d;
				else
					case (hk)
						8'h00: hw_id <= d;
						8'h01: dvi_only <= d[0];
						8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17:
							core_build[(7 - hk[2:0]) * 8 +: 8] <= d;
						8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F:
							fw_build[(7 - hk[2:0]) * 8 +: 8] <= d;
						default: ;
					endcase
			8'h05: if (n == 10'd0) busy <= d[0];
			8'h06:
				if (n == 10'd0) begin
					ft_spi_on <= d[0];
					ft_vga_on <= d[1];
					ft_reset <= d[4];
				end
			8'h07:
				if (n == 10'd0)
					idx <= d;
				else if (n == 10'd1 && idx[7:1] == 7'd0)
					btns[idx[0]] <= d[0];
			default: ;
		endcase
end

endmodule
