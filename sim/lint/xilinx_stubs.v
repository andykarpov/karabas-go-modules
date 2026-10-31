// Black boxes for verilator --lint-only (run_lint.sh): the parameters and ports of the Xilinx
// primitives and of the VHDL entities the Verilog modules instantiate. The primitives are taken
// from the unisims of ISE 14.7 (verilog/src/unisims), interface only.

/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off MULTITOP */

module PLL_BASE #(
	parameter BANDWIDTH = "OPTIMIZED",
	parameter CLKFBOUT_MULT = 1,
	parameter CLKFBOUT_PHASE = 0.0,
	parameter CLKIN_PERIOD = 0.000,
	parameter CLKOUT0_DIVIDE = 1,
	parameter CLKOUT0_DUTY_CYCLE = 0.5,
	parameter CLKOUT0_PHASE = 0.0,
	parameter CLKOUT1_DIVIDE = 1,
	parameter CLKOUT1_DUTY_CYCLE = 0.5,
	parameter CLKOUT1_PHASE = 0.0,
	parameter CLKOUT2_DIVIDE = 1,
	parameter CLKOUT2_DUTY_CYCLE = 0.5,
	parameter CLKOUT2_PHASE = 0.0,
	parameter CLKOUT3_DIVIDE = 1,
	parameter CLKOUT3_DUTY_CYCLE = 0.5,
	parameter CLKOUT3_PHASE = 0.0,
	parameter CLKOUT4_DIVIDE = 1,
	parameter CLKOUT4_DUTY_CYCLE = 0.5,
	parameter CLKOUT4_PHASE = 0.0,
	parameter CLKOUT5_DIVIDE = 1,
	parameter CLKOUT5_DUTY_CYCLE = 0.5,
	parameter CLKOUT5_PHASE = 0.0,
	parameter CLK_FEEDBACK = "CLKFBOUT",
	parameter COMPENSATION = "SYSTEM_SYNCHRONOUS",
	parameter DIVCLK_DIVIDE = 1,
	parameter REF_JITTER = 0.100,
	parameter RESET_ON_LOSS_OF_LOCK = "FALSE"
) (
	output wire CLKFBOUT,
	output wire CLKOUT0,
	output wire CLKOUT1,
	output wire CLKOUT2,
	output wire CLKOUT3,
	output wire CLKOUT4,
	output wire CLKOUT5,
	output wire LOCKED,
	input wire CLKFBIN,
	input wire CLKIN,
	input wire RST
);
assign CLKFBOUT = 0;
assign CLKOUT0 = 0;
assign CLKOUT1 = 0;
assign CLKOUT2 = 0;
assign CLKOUT3 = 0;
assign CLKOUT4 = 0;
assign CLKOUT5 = 0;
assign LOCKED = 0;
endmodule

module DCM_SP #(
	parameter CLKDV_DIVIDE = 2.0,
	parameter CLKFX_DIVIDE = 1,
	parameter CLKFX_MULTIPLY = 4,
	parameter CLKIN_DIVIDE_BY_2 = "FALSE",
	parameter CLKIN_PERIOD = 10.0,
	parameter CLKOUT_PHASE_SHIFT = "NONE",
	parameter CLK_FEEDBACK = "1X",
	parameter DESKEW_ADJUST = "SYSTEM_SYNCHRONOUS",
	parameter DFS_FREQUENCY_MODE = "LOW",
	parameter DLL_FREQUENCY_MODE = "LOW",
	parameter DSS_MODE = "NONE",
	parameter DUTY_CYCLE_CORRECTION = "TRUE",
	parameter FACTORY_JF = 16'hC080,
	parameter PHASE_SHIFT = 0,
	parameter STARTUP_WAIT = "FALSE"
) (
	input wire CLKFB,
	input wire CLKIN,
	input wire DSSEN,
	input wire PSCLK,
	input wire PSEN,
	input wire PSINCDEC,
	input wire RST,
	output wire CLK0,
	output wire CLK180,
	output wire CLK270,
	output wire CLK2X,
	output wire CLK2X180,
	output wire CLK90,
	output wire CLKDV,
	output wire CLKFX,
	output wire CLKFX180,
	output wire LOCKED,
	output wire PSDONE,
	output wire [7:0] STATUS
);
assign CLK0 = 0;
assign CLK180 = 0;
assign CLK270 = 0;
assign CLK2X = 0;
assign CLK2X180 = 0;
assign CLK90 = 0;
assign CLKDV = 0;
assign CLKFX = 0;
assign CLKFX180 = 0;
assign LOCKED = 0;
assign PSDONE = 0;
assign STATUS = 0;
endmodule

module BUFG #(

) (
	output wire O,
	input wire I
);
assign O = 0;
endmodule

module DCM_CLKGEN #(
	parameter SPREAD_SPECTRUM = "NONE",
	parameter STARTUP_WAIT = "FALSE",
	parameter integer CLKFXDV_DIVIDE = 2,
	parameter integer CLKFX_DIVIDE = 1,
	parameter integer CLKFX_MULTIPLY = 4,
	parameter real CLKFX_MD_MAX = 0.0,
	parameter real CLKIN_PERIOD = 0.0
) (
	output wire CLKFX180,
	output wire CLKFX,
	output wire CLKFXDV,
	output wire LOCKED,
	output wire PROGDONE,
	output wire [2:1] STATUS,
	input wire CLKIN,
	input wire FREEZEDCM,
	input wire PROGCLK,
	input wire PROGDATA,
	input wire PROGEN,
	input wire RST
);
assign CLKFX180 = 0;
assign CLKFX = 0;
assign CLKFXDV = 0;
assign LOCKED = 0;
assign PROGDONE = 0;
assign STATUS = 0;
endmodule

module BUFGMUX #(
	parameter CLK_SEL_TYPE = "SYNC"
) (
	output wire O,
	input wire I0,
	input wire I1,
	input wire S
);
assign O = 0;
endmodule

module IBUFG #(
	parameter CAPACITANCE = "DONT_CARE",
	parameter IBUF_DELAY_VALUE = "0",
	parameter IBUF_LOW_PWR = "TRUE",
	parameter IOSTANDARD = "DEFAULT"
) (
	output wire O,
	input wire I
);
assign O = 0;
endmodule

// rtl/video/hdmi/zhdmi_tx.vhd
module hdmi_tx #(
	parameter SAMPLE_FREQ = 32000,
	parameter [3:0] INVERTED_TX = 4'b0000
) (
	input wire clk,
	input wire sclk,
	input wire sclk_n,
	input wire reset,
	input wire [23:0] rgb,
	input wire vsync,
	input wire hsync,
	input wire de,
	input wire audio_en,
	input wire [23:0] audio_l,
	input wire [23:0] audio_r,
	input wire audio_clk,
	output wire tx_clk_n,
	output wire tx_clk_p,
	output wire [2:0] tx_d_n,
	output wire [2:0] tx_d_p
);
assign tx_clk_n = 1'b0;
assign tx_clk_p = 1'b0;
assign tx_d_n = 3'b000;
assign tx_d_p = 3'b000;
endmodule
