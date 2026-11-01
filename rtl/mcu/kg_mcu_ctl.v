`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_mcu_ctl.v

 The control commands of the MCU link (a decoder on the frame bus of kg_mcu_link):
   SWITCHES a d   softsw_command = a d (kg_soft_switches takes it)
   OSD a d        osd_command = a d (kg_osd_overlay takes it)
   HW_SETUP 00 d  hwid; HW_SETUP 01 d: dvi_only = d[0]
   HW_SETUP 1i d  core_build character i (0..7); HW_SETUP 1(8+i) d: fw_build character i: the build ids of the
                  core (.kg header) and of the firmware, ASCII, character 0 in bits 63..56, 0 after a shorter id
   BTNS n d       btns[n] = d[0] (n 0, 1)
   CONTROL x d    ft_spi_on = d[0], ft_vga_on = d[1], ft_reset = d[4] (any address)
   INIT_START     busy = 1 (also after configuration); INIT_DONE: busy = 0
*/

module kg_mcu_ctl (
	input wire clk,
	input wire rx_stb,
	input wire [7:0] rx_cmd,
	input wire [7:0] rx_addr,
	input wire [7:0] rx_data,

	output reg [15:0] softsw_command = 16'd0,
	output reg [15:0] osd_command = 16'd0,
	output reg [7:0] hwid = 8'd0,
	output reg dvi_only = 1'b0,
	output reg [63:0] core_build = 64'd0,
	output reg [63:0] fw_build = 64'd0,
	output wire [1:0] btns,
	output reg ft_spi_on = 1'b0,
	output reg ft_vga_on = 1'b0,
	output reg ft_reset = 1'b0,
	output reg busy = 1'b1
);

`include "kg_mcu_cmds.vh"

reg btn0 = 1'b0, btn1 = 1'b0; // separate: see kg_mcu_hid
assign btns = { btn1, btn0 };

always @(posedge clk)
	if (rx_stb)
		case (rx_cmd)
			CMD_SWITCHES: softsw_command <= { rx_addr, rx_data };
			CMD_OSD: osd_command <= { rx_addr, rx_data };
			CMD_HW_SETUP:
				case (rx_addr)
					8'h00: hwid <= rx_data;
					8'h01: dvi_only <= rx_data[0];
					8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17:
						core_build[(7 - rx_addr[2:0]) * 8 +: 8] <= rx_data;
					8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F:
						fw_build[(7 - rx_addr[2:0]) * 8 +: 8] <= rx_data;
					default: ;
				endcase
			CMD_BTNS:
				case (rx_addr)
					8'h00: btn0 <= rx_data[0];
					8'h01: btn1 <= rx_data[0];
					default: ;
				endcase
			CMD_CONTROL: begin
				ft_spi_on <= rx_data[0];
				ft_vga_on <= rx_data[1];
				ft_reset <= rx_data[4];
			end
			CMD_INIT_START: busy <= 1'b1;
			CMD_INIT_DONE: busy <= 1'b0;
			default: ;
		endcase

endmodule
