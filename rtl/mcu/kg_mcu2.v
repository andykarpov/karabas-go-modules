`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_mcu2.v

 The MCU of the board over link v2 (karabas-go-firmware docs/link_v2.md): packets on MCU_SS,
 the interrupt line MCU_INT (active high, the IO1 line: MCU_IO[1] on Mini / Mini G,
 MCU_SPI_IO[0] on Go), and the targets SYS, HID, LOAD. A core of link v2 uses this module only
 (not kg_mcu) and says "link": 2 in its core.json.

 The other slaves of the MCU bus (FT812, SD2) are passed through as in kg_mcu: their chip selects
 come from the MCU, MISO is muxed.

 Core side (all in CLK):
 - SYS: SW_WR one clock per OSD switch (SW_INDEX = the switch index of core.json, SW_VALUE);
   HW_ID, DVI_ONLY, CORE_BUILD / FW_BUILD (ASCII, character 0 in bits 63..56), BUSY (the mcu
   configures the core), BTNS (the on-board buttons with the action "core"), FT_*;
   RELOAD_REQ (a rising edge asks the mcu to load the core again through the boot core).
 - HID: KBD (the USB boot report: bits 7..0 modifiers, then the 6 key codes) with KBD_WR; PS2
   bytes (PS2_KIND 0 set 2, 1 XT with bit 7 release) with PS2_WR; the mouse (MS_X / MS_Y / MS_Z
   signed deltas, MS_B buttons) with MS_WR; JOY_L / JOY_R with JOY_WR; PS2_CMD (command,
   argument) with PS2_CMD_WR to the mcu (keyboard LEDs, scancode set).
 - LOAD: LD_* of kg_l2_load (ROMs, file loader, FL items on one bus), LD_READY from the core.

 Parameters: CAPS (STATUS caps, docs/link_v2.md 5.1; bit 4 = the core drives LD_READY),
 CS_FILTER (the chip select deglitch of kg_mcu_link), ENABLE_FT / ENABLE_SD2.
*/

module kg_mcu2 #(
	parameter [15:0] CAPS = 16'h0000,
	parameter CS_FILTER = 3,
	parameter ENABLE_FT = 1,
	parameter ENABLE_SD2 = 1
) (
	input wire CLK,
	input wire N_RESET,

	input wire MCU_SCK,
	input wire MCU_MOSI,
	output wire MCU_MISO,
	input wire MCU_SS,
	output wire MCU_INT,
	input wire MCU_SPI_FT_SS,
	input wire MCU_SPI_SD2_SS,

	// sys
	output wire SW_WR,
	output wire [7:0] SW_INDEX,
	output wire [7:0] SW_VALUE,
	output wire [7:0] HW_ID,
	output wire DVI_ONLY,
	output wire [63:0] CORE_BUILD,
	output wire [63:0] FW_BUILD,
	output wire BUSY,
	output wire [1:0] BTNS,
	input wire RELOAD_REQ,
	input wire [7:0] RELOAD_CORE,

	// hid
	output wire [55:0] KBD,
	output wire KBD_WR,
	output wire [7:0] PS2_CODE,
	output wire PS2_KIND,
	output wire PS2_WR,
	output wire [7:0] MS_X,
	output wire [7:0] MS_Y,
	output wire [7:0] MS_Z,
	output wire [7:0] MS_B,
	output wire MS_WR,
	output wire [15:0] JOY_L,
	output wire [15:0] JOY_R,
	output wire JOY_WR,
	input wire [15:0] PS2_CMD,
	input wire PS2_CMD_WR,

	// load
	output wire [1:0] LD_KIND,
	output wire [7:0] LD_SLOT,
	output wire [31:0] LD_SIZE,
	output wire LD_START,
	output wire LD_ACTIVE,
	output wire LD_END,
	output wire [31:0] LD_ADDR,
	output wire [7:0] LD_DATA,
	output wire LD_WR,
	input wire LD_READY,

	// ft812, sd2
	output wire FT_SPI_ON,
	output wire FT_VGA_ON,
	output wire FT_RESET,
	output wire FT_SCK,
	output wire FT_MOSI,
	input wire FT_MISO,
	output wire FT_CS_N,
	output wire SD2_SCK,
	output wire SD2_MOSI,
	input wire SD2_MISO,
	output wire SD2_CS_N
);

// ---------------- link ----------------

wire stb, start, rq;
wire [7:0] tgt, cmd, d;
wire [9:0] n, rq_m;
wire spi_miso, spi_sel;
wire [7:0] irq;
wire [7:0] q_sys, q_hid, q_load;

/* verilator lint_off UNUSEDSIGNAL */
wire start_u = start; // the targets look at stb / rq only
/* verilator lint_on UNUSEDSIGNAL */

kg_l2_link #(.CS_FILTER(CS_FILTER)) u_link(
	.clk(CLK),
	.sck(MCU_SCK), .mosi(MCU_MOSI), .miso(spi_miso), .miso_en(spi_sel), .cs_n(MCU_SS),
	.stb(stb), .start(start), .tgt(tgt), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m),
	.q(tgt == 8'h00 ? q_sys : tgt == 8'h01 ? q_hid : tgt == 8'h04 ? q_load : 8'h00),
	.irq(irq), .int_out(MCU_INT)
);

assign MCU_MISO = spi_sel ? spi_miso :
	(ENABLE_SD2 && !MCU_SPI_SD2_SS) ? SD2_MISO :
	(ENABLE_FT && !MCU_SPI_FT_SS) ? FT_MISO : 1'b1;

assign FT_SCK = ENABLE_FT ? MCU_SCK : 1'b1;
assign FT_MOSI = ENABLE_FT ? MCU_MOSI : 1'b1;
assign FT_CS_N = ENABLE_FT ? MCU_SPI_FT_SS : 1'b1;
assign SD2_SCK = ENABLE_SD2 ? MCU_SCK : 1'b1;
assign SD2_MOSI = ENABLE_SD2 ? MCU_MOSI : 1'b1;
assign SD2_CS_N = ENABLE_SD2 ? MCU_SPI_SD2_SS : 1'b1;

// ---------------- targets ----------------

wire irq_sys, irq_hid;
assign irq = { 6'd0, irq_hid, irq_sys };

kg_l2_sys #(.CAPS(CAPS)) u_sys(
	.clk(CLK), .reset(~N_RESET),
	.sel(tgt == 8'h00), .stb(stb), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m), .q(q_sys),
	.pending(irq), .irq(irq_sys),
	.sw_wr(SW_WR), .sw_index(SW_INDEX), .sw_value(SW_VALUE),
	.hw_id(HW_ID), .dvi_only(DVI_ONLY), .core_build(CORE_BUILD), .fw_build(FW_BUILD), .busy(BUSY),
	.ft_spi_on(FT_SPI_ON), .ft_vga_on(FT_VGA_ON), .ft_reset(FT_RESET), .btns(BTNS),
	.reload_req(RELOAD_REQ), .reload_core(RELOAD_CORE)
);

kg_l2_hid u_hid(
	.clk(CLK),
	.sel(tgt == 8'h01), .stb(stb), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m), .q(q_hid),
	.irq(irq_hid),
	.kbd(KBD), .kbd_wr(KBD_WR), .ps2_code(PS2_CODE), .ps2_kind(PS2_KIND), .ps2_wr(PS2_WR),
	.ms_x(MS_X), .ms_y(MS_Y), .ms_z(MS_Z), .ms_b(MS_B), .ms_wr(MS_WR),
	.joy_l(JOY_L), .joy_r(JOY_R), .joy_wr(JOY_WR),
	.cmd_data(PS2_CMD), .cmd_wr(PS2_CMD_WR)
);

kg_l2_load u_load(
	.clk(CLK),
	.sel(tgt == 8'h04), .stb(stb), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m), .q(q_load),
	.ld_kind(LD_KIND), .ld_slot(LD_SLOT), .ld_size(LD_SIZE), .ld_start(LD_START),
	.ld_active(LD_ACTIVE), .ld_end(LD_END), .ld_addr(LD_ADDR), .ld_data(LD_DATA), .ld_wr(LD_WR),
	.ld_ready(LD_READY)
);

endmodule
