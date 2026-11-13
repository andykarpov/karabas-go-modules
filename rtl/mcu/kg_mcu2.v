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
 - SYS: the OSD switches: SW, SW_N registers of 8 bits (switch n = SW[n*8 +: 8], the index of
   core.json; indexes from SW_N up are not kept), SW_INIT their values before the first write;
   SW_WR one clock per write with SW_INDEX / SW_VALUE for a core that wants the moment;
   HW_ID, DVI_ONLY, CORE_BUILD / FW_BUILD (ASCII, character 0 in bits 63..56), BUSY (the mcu
   configures the core), BTNS (the on-board buttons with the action "core"), FT_*;
   RELOAD_REQ (a rising edge asks the mcu to load the core again through the boot core).
 - HID: KBD (the USB boot report: bits 7..0 modifiers, then the 6 key codes) with KBD_WR; PS2
   bytes (PS2_KIND 0 set 2, 1 XT with bit 7 release) with PS2_WR; the mouse (MS_X / MS_Y / MS_Z
   signed deltas, MS_B buttons) with MS_WR; JOY_L / JOY_R with JOY_WR; PS2_CMD (command,
   argument) with PS2_CMD_WR to the mcu (keyboard LEDs, scancode set).
 - OSD (ENABLE_OSD): OSD_* of kg_l2_osd to kg_l2_osd_overlay (the bitmap and the drawing, in the
   video clock); STATUS reports 256 x 128 then.
 - LOAD: LD_* of kg_l2_load (ROMs, file loader, FL items on one bus), LD_READY from the core.
 - PORT (ENABLE_PORTS, bit n = port n: 0 USB serial, 1 ESP8266, 2 MIDI IN, 3 USB printer): one
   kg_l2_port each, its bytes for the core on PORT_OUT_DATA[n*8 +: 8] with PORT_OUT_WR[n] while
   PORT_OUT_READY[n], its bytes to the mcu PORT_IN_DATA / PORT_IN_WR / PORT_IN_FULL, PORT_CFG[n*32
   +: 32] (port 0: the divisor DLL, DLM; port 3: bit 0 asks for the printer status),
   PORT_STAT / PORT_STAT_WR (port 3: the printer status, bit 7 BUSY). STATUS reports the mask.
 - RTC (ENABLE_RTC): the clock registers of kg_l2_rtc as kg_mcu_rtc (RTC_A -> RTC_DO a clock
   later, RTC_DI written with RTC_CS and !RTC_WR_N), RTC_SKIP_0D, RTC_SEND_LIMIT.
 - AUX (ENABLE_AUX): MATRIX_CMD / MATRIX_CMD_WR, the frames of v1 (matrix CTL / PIXEL / BITPLAN,
   the audio peaks of audio_peaks.v), DEBUG_ADDR / DEBUG_DATA; kg_l2_aux keeps them for the mcu.
 - CAPS bits 0 (IMG), 5 (RTC), 6 (AUX) are set from ENABLE_IMG / _RTC / _AUX.
 - IMG (ENABLE_IMG): the file mounter of kg_l2_img as the sector interface of img_sdc (SDC_*,
   the drives of the cores as they are), IMG_WP, IMG_PHYS, IMG_FLUSH, FDD_CHNG; CAPS bit 0 says
   so to the mcu (bit 2: write protected images are answered). BK_*: the events of kg_bk_ram
   (LINK 2): BK_MOUNT / BK_FLUSHED one clock with BK_SLOT, BK_SIZE, BK_KIND / BK_RESULT (CAPS bit 1:
   the firmware sends FLUSH before it loads another game or core).

 Parameters: CAPS (STATUS caps, docs/link_v2.md 5.1; bit 4 = the core drives LD_READY, bit 9 =
 MIDI IN), SW_N / SW_INIT,
 CS_FILTER (the chip select deglitch of kg_mcu_link), ENABLE_FT / ENABLE_SD2.
*/

module kg_mcu2 #(
	parameter [15:0] CAPS = 16'h0000,
	parameter SW_N = 16,
	parameter [SW_N*8-1:0] SW_INIT = 0,
	parameter CS_FILTER = 3,
	parameter ENABLE_OSD = 1,     // the bitmap OSD (target 02): OSD_* to kg_l2_osd_overlay
	parameter ENABLE_IMG = 0,     // the file mounter (target 03): SDC_*, IMG_*
	parameter [3:0] ENABLE_PORTS = 4'b0000, // PORT (target 05): bit n = port n
	parameter ENABLE_RTC = 0,     // RTC (target 06): RTC_*
	parameter RTC_SKIP_0D = 1,
	parameter RTC_SEND_LIMIT = 256,
	parameter ENABLE_AUX = 0,     // AUX (target 07): MATRIX_CMD, DEBUG_*
	parameter PORT_OUT_AW = 5,    // the fifos of each port: 2^AW bytes
	parameter PORT_IN_AW = 5,
	parameter IMG_OUT_LATENCY = 3, // kg_l2_img: clocks from SDC_BYTE_ADDR to SDC_BYTE_OUT_DATA
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
	output reg [SW_N*8-1:0] SW = SW_INIT, // written per byte in the generate below
	output wire SW_WR,
	output wire [7:0] SW_INDEX,
	output wire [7:0] SW_VALUE,
	output wire [7:0] HW_ID,
	output wire DVI_ONLY,
	output wire [63:0] CORE_BUILD,
	output wire [63:0] FW_BUILD,
	output wire BUSY,
	output wire [5:0] BTNS, // 0, 1 the board, 2..5 the LED matrix buttons
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

	// osd (ENABLE_OSD): to kg_l2_osd_overlay in the video clock
	output wire OSD_WR,
	output wire [11:0] OSD_WADDR,
	output wire [7:0] OSD_WDATA,
	output wire OSD_EN,
	output wire [23:0] OSD_FG,
	output wire [23:0] OSD_BG,
	output wire [1:0] OSD_ALPHA,
	output wire [4:0] OSD_PX,
	output wire [3:0] OSD_PY,
	output wire [5:0] OSD_PW,
	output wire [4:0] OSD_PH,
	output wire [1:0] OSD_PLACE,
	output wire OSD_ZOOM,

	// img (ENABLE_IMG): kg_l2_img, the sd card interface of img_sdc
	output wire [7:0] SDC_IMG_MOUNTED,
	output wire [63:0] SDC_IMG_SIZE,
	/* verilator lint_off UNUSEDSIGNAL */ // ENABLE_IMG 0
	input wire [7:0] SDC_RD,
	input wire [7:0] SDC_WR,
	input wire [31:0] SDC_SECTOR,
	/* verilator lint_on UNUSEDSIGNAL */
	output wire SDC_BUSY,
	output wire SDC_DONE,
	output wire SDC_ERROR,
	output wire [2:0] SDC_SLOT,
	output wire SDC_BYTE_IN_STROBE,
	output wire [8:0] SDC_BYTE_ADDR,
	output wire [7:0] SDC_BYTE_IN_DATA,
	/* verilator lint_off UNUSEDSIGNAL */ // ENABLE_IMG 0
	input wire [7:0] SDC_BYTE_OUT_DATA,
	/* verilator lint_on UNUSEDSIGNAL */
	output wire [7:0] IMG_WP,
	output wire IMG_PHYS_WR,
	output wire [15:0] IMG_PHYS,
	output wire [7:0] IMG_FLUSH,
	output wire FDD_CHNG_WR,
	output wire [15:0] FDD_CHNG,
	/* verilator lint_off UNUSEDSIGNAL */ // ENABLE_IMG 0
	input wire FDD_CHNG_REQ,
	input wire [1:0] FDD_CHNG_DS,
	input wire BK_MOUNT,
	input wire BK_FLUSHED,
	input wire [2:0] BK_SLOT,
	input wire [31:0] BK_SIZE,
	input wire [7:0] BK_KIND,
	input wire [7:0] BK_RESULT,
	/* verilator lint_on UNUSEDSIGNAL */
	output wire IMG_ACTIVE,

	// port (ENABLE_PORTS): port n in bits [n*8 +: 8], [n]
	output wire [31:0] PORT_OUT_DATA,
	output wire [3:0] PORT_OUT_WR,
	/* verilator lint_off UNUSEDSIGNAL */ // the ports not enabled
	input wire [3:0] PORT_OUT_READY,
	input wire [31:0] PORT_IN_DATA,
	input wire [3:0] PORT_IN_WR,
	input wire [127:0] PORT_CFG,
	/* verilator lint_on UNUSEDSIGNAL */
	output wire [3:0] PORT_IN_FULL,
	output wire [31:0] PORT_STAT,
	output wire [3:0] PORT_STAT_WR,

	// rtc (ENABLE_RTC)
	/* verilator lint_off UNUSEDSIGNAL */ // ENABLE_RTC / ENABLE_AUX 0
	input wire [7:0] RTC_A,
	input wire [7:0] RTC_DI,
	input wire RTC_CS,
	input wire RTC_WR_N,
	// aux (ENABLE_AUX)
	input wire [23:0] MATRIX_CMD,
	input wire MATRIX_CMD_WR,
	input wire [15:0] DEBUG_ADDR,
	input wire [15:0] DEBUG_DATA,
	/* verilator lint_on UNUSEDSIGNAL */
	output wire [7:0] RTC_DO,

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
wire [7:0] q_sys, q_hid, q_load, q_img, q_port, q_rtc, q_aux;

/* verilator lint_off UNUSEDSIGNAL */
wire start_u = start; // only kg_l2_img looks at it
/* verilator lint_on UNUSEDSIGNAL */

kg_l2_link #(.CS_FILTER(CS_FILTER)) u_link(
	.clk(CLK),
	.sck(MCU_SCK), .mosi(MCU_MOSI), .miso(spi_miso), .miso_en(spi_sel), .cs_n(MCU_SS),
	.stb(stb), .start(start), .tgt(tgt), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m),
	.q(tgt == 8'h00 ? q_sys : tgt == 8'h01 ? q_hid : tgt == 8'h03 ? q_img : tgt == 8'h04 ? q_load : tgt == 8'h05 ? q_port : tgt == 8'h06 ? q_rtc : tgt == 8'h07 ? q_aux : 8'h00), // OSD answers nothing
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

// ---------------- the switch registers ----------------

// one register per switch (a clock enable each; see kg_mcu_hid)
genvar g;
generate
	for (g = 0; g < SW_N; g = g + 1) begin : kg_mcu2_sw
		localparam [7:0] IDX = g;
		always @(posedge CLK)
			if (SW_WR && SW_INDEX == IDX)
				SW[g*8 +: 8] <= SW_VALUE;
	end
endgenerate

// ---------------- targets ----------------

wire irq_sys, irq_hid, irq_img, irq_port, irq_rtc, irq_aux;
assign irq = { irq_aux, irq_rtc, irq_port, 1'b0, irq_img, 1'b0, irq_hid, irq_sys };
localparam [15:0] CAPS_ALL = CAPS | (ENABLE_IMG ? 16'h0001 : 16'h0000) | (ENABLE_RTC ? 16'h0020 : 16'h0000) |
	(ENABLE_AUX ? 16'h0040 : 16'h0000);

kg_l2_sys #(.CAPS(CAPS_ALL), .PORTS({ 4'd0, ENABLE_PORTS }), .OSD_W8(ENABLE_OSD ? 8'd32 : 8'd0), .OSD_H8(ENABLE_OSD ? 8'd16 : 8'd0)) u_sys(
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

generate
	if (ENABLE_OSD) begin : kg_mcu2_osd_on
		kg_l2_osd u_osd(
			.clk(CLK),
			.sel(tgt == 8'h02), .stb(stb), .cmd(cmd), .n(n), .d(d),
			.osd_wr(OSD_WR), .osd_waddr(OSD_WADDR), .osd_wdata(OSD_WDATA), .osd_en(OSD_EN),
			.osd_fg(OSD_FG), .osd_bg(OSD_BG), .osd_alpha(OSD_ALPHA),
			.osd_px(OSD_PX), .osd_py(OSD_PY), .osd_pw(OSD_PW), .osd_ph(OSD_PH),
			.osd_place(OSD_PLACE), .osd_zoom(OSD_ZOOM)
		);
	end
	else begin : kg_mcu2_osd_off
		assign OSD_WR = 1'b0;
		assign OSD_WADDR = 12'd0;
		assign OSD_WDATA = 8'd0;
		assign OSD_EN = 1'b0;
		assign OSD_FG = 24'd0;
		assign OSD_BG = 24'd0;
		assign OSD_ALPHA = 2'd0;
		assign OSD_PX = 5'd0;
		assign OSD_PY = 4'd0;
		assign OSD_PW = 6'd0;
		assign OSD_PH = 5'd0;
		assign OSD_PLACE = 2'd0;
		assign OSD_ZOOM = 1'b0;
	end
endgenerate

generate
	if (ENABLE_IMG) begin : kg_mcu2_img_on
		kg_l2_img #(.OUT_LATENCY(IMG_OUT_LATENCY)) u_img(
			.clk(CLK), .reset(~N_RESET),
			.sel(tgt == 8'h03), .start(start), .stb(stb), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m),
			.q(q_img), .irq(irq_img),
			.sdc_img_mounted(SDC_IMG_MOUNTED), .sdc_img_size(SDC_IMG_SIZE), .sdc_rd(SDC_RD),
			.sdc_wr(SDC_WR), .sdc_sector(SDC_SECTOR), .sdc_busy(SDC_BUSY), .sdc_done(SDC_DONE),
			.sdc_error(SDC_ERROR), .sdc_slot(SDC_SLOT), .sdc_byte_in_strobe(SDC_BYTE_IN_STROBE),
			.sdc_byte_addr(SDC_BYTE_ADDR), .sdc_byte_in_data(SDC_BYTE_IN_DATA),
			.sdc_byte_out_data(SDC_BYTE_OUT_DATA),
			.img_wp(IMG_WP), .img_phys_wr(IMG_PHYS_WR), .img_phys(IMG_PHYS), .img_flush(IMG_FLUSH),
			.fdd_chng_wr(FDD_CHNG_WR), .fdd_chng(FDD_CHNG), .fdd_chng_req(FDD_CHNG_REQ),
			.fdd_chng_ds(FDD_CHNG_DS),
			.bk_mount(BK_MOUNT), .bk_flushed(BK_FLUSHED), .bk_slot(BK_SLOT), .bk_size(BK_SIZE),
			.bk_kind(BK_KIND), .bk_result(BK_RESULT),
			.active(IMG_ACTIVE)
		);
	end
	else begin : kg_mcu2_img_off
		assign q_img = 8'h00;
		assign irq_img = 1'b0;
		assign SDC_IMG_MOUNTED = 8'd0;
		assign SDC_IMG_SIZE = 64'd0;
		assign SDC_BUSY = 1'b0;
		assign SDC_DONE = 1'b0;
		assign SDC_ERROR = 1'b0;
		assign SDC_SLOT = 3'd0;
		assign SDC_BYTE_IN_STROBE = 1'b0;
		assign SDC_BYTE_ADDR = 9'd0;
		assign SDC_BYTE_IN_DATA = 8'd0;
		assign IMG_WP = 8'd0;
		assign IMG_PHYS_WR = 1'b0;
		assign IMG_PHYS = 16'd0;
		assign IMG_FLUSH = 8'd0;
		assign FDD_CHNG_WR = 1'b0;
		assign FDD_CHNG = 16'd0;
		assign IMG_ACTIVE = 1'b0;
	end
endgenerate

wire [31:0] q_ports;
wire [3:0] irq_ports;
generate
	for (g = 0; g < 4; g = g + 1) begin : kg_mcu2_port
		if (ENABLE_PORTS[g]) begin : on
			kg_l2_port #(.INDEX(g), .OUT_AW(PORT_OUT_AW), .IN_AW(PORT_IN_AW)) u_port(
				.clk(CLK), .reset(~N_RESET),
				.sel(tgt == 8'h05), .stb(stb), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m),
				.q(q_ports[g*8 +: 8]), .irq(irq_ports[g]),
				.out_data(PORT_OUT_DATA[g*8 +: 8]), .out_wr(PORT_OUT_WR[g]), .out_ready(PORT_OUT_READY[g]),
				.in_data(PORT_IN_DATA[g*8 +: 8]), .in_wr(PORT_IN_WR[g]), .in_full(PORT_IN_FULL[g]),
				.cfg(PORT_CFG[g*32 +: 32]), .stat(PORT_STAT[g*8 +: 8]), .stat_wr(PORT_STAT_WR[g])
			);
		end
		else begin : off
			assign q_ports[g*8 +: 8] = 8'h00;
			assign irq_ports[g] = 1'b0;
			assign PORT_OUT_DATA[g*8 +: 8] = 8'h00;
			assign PORT_OUT_WR[g] = 1'b0;
			assign PORT_IN_FULL[g] = 1'b1;
			assign PORT_STAT[g*8 +: 8] = 8'h00;
			assign PORT_STAT_WR[g] = 1'b0;
		end
	end
endgenerate
assign q_port = q_ports[7:0] | q_ports[15:8] | q_ports[23:16] | q_ports[31:24];
assign irq_port = |irq_ports;

generate
	if (ENABLE_RTC) begin : kg_mcu2_rtc_on
		kg_l2_rtc #(.SKIP_0D(RTC_SKIP_0D), .SEND_LIMIT(RTC_SEND_LIMIT)) u_rtc(
			.clk(CLK),
			.sel(tgt == 8'h06), .stb(stb), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m),
			.q(q_rtc), .irq(irq_rtc), .busy(BUSY),
			.rtc_a(RTC_A), .rtc_di(RTC_DI), .rtc_do(RTC_DO), .rtc_cs(RTC_CS), .rtc_wr_n(RTC_WR_N)
		);
	end
	else begin : kg_mcu2_rtc_off
		assign q_rtc = 8'h00;
		assign irq_rtc = 1'b0;
		assign RTC_DO = 8'h00;
	end
	if (ENABLE_AUX) begin : kg_mcu2_aux_on
		kg_l2_aux u_aux(
			.clk(CLK),
			.sel(tgt == 8'h07), .cmd(cmd), .rq(rq), .rq_m(rq_m), .q(q_aux), .irq(irq_aux),
			.matrix_cmd(MATRIX_CMD), .matrix_cmd_wr(MATRIX_CMD_WR),
			.debug_addr(DEBUG_ADDR), .debug_data(DEBUG_DATA)
		);
	end
	else begin : kg_mcu2_aux_off
		assign q_aux = 8'h00;
		assign irq_aux = 1'b0;
	end
endgenerate

kg_l2_load u_load(
	.clk(CLK),
	.sel(tgt == 8'h04), .stb(stb), .cmd(cmd), .n(n), .d(d), .rq(rq), .rq_m(rq_m), .q(q_load),
	.ld_kind(LD_KIND), .ld_slot(LD_SLOT), .ld_size(LD_SIZE), .ld_start(LD_START),
	.ld_active(LD_ACTIVE), .ld_end(LD_END), .ld_addr(LD_ADDR), .ld_data(LD_DATA), .ld_wr(LD_WR),
	.ld_ready(LD_READY)
);

endmodule
