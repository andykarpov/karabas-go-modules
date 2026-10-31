`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_mcu.v

 The MCU of the board as mcu.vhd showed it to the cores, built from kg_mcu_link and the command
 decoders: the ports of mcu.vhd (karabas-go-core-nanomig, tsconf, and the file loader of rk86,
 spec256, alf, nes; the ESP uart of menu; the flashboot of next) with the same names, so a top changes the module name only. A core that wants
 less can put kg_mcu_link and the decoders it needs in its top instead.

 Differences to the mcu.vhd of the cores (nanomig: none but CS_FILTER):
 - CS_FILTER 3: the chip select deglitch that nanomig had in its top (remove it there);
 - the link fixes of nanomig for all (kg_mcu_link): a core that took its reply word on di_req
   (tsconf and the others) lost words when sck ran without its chip select;
 - a frame is decoded once: the cores that decoded on the level of do_valid (two clocks) toggled
   MS_UPD and the scancode flags twice;
 - rom_wr: turning the rom loader on writes nothing (the cores without the nanomig fix wrote the
   last address again);
 - inputs have no default values (Verilog): tie the inputs of enabled features in the top;
 - no buffer ports.

 Transmit priority: CAPS, uart byte, dll, dlm, rtc, matrix, debug addr, debug data, img, esp,
 flashboot.
*/

module kg_mcu #(
	parameter BURST_MAX_MHZ = 0,    // highest burst sck in the CAPS answer, MHz (0 = 16)
	parameter CS_FILTER = 3,        // clocks a chip select must be high (0 = not filtered)
	parameter ENABLE_RTC = 1,
	parameter RTC_SKIP_0D = 1,      // nanomig 1, tsconf 0
	parameter RTC_SEND_LIMIT = 256, // nanomig 256, tsconf 'hF0
	parameter ENABLE_UART = 1,
	parameter ENABLE_MATRIX = 1,
	parameter ENABLE_DEBUG = 0,
	parameter ENABLE_IMG = 0,
	parameter ENABLE_BK = 0,        // caps bit 3: the core has kg_bk_ram on the file mounter (needs ENABLE_IMG)
	parameter ENABLE_FILE = 1,      // file loader (ioctl / file commands), see kg_mcu_loader
	parameter FILE_CMDS = 0,
	parameter FILE_WR_EACH = 1,
	parameter FILE_TO_ROM = 1,
	parameter ENABLE_FT = 1,        // FT812 chip select passed through
	parameter ENABLE_SD2 = 1,       // second SD card chip select passed through
	parameter ENABLE_ESP = 0,       // the ESP8266 uart bridge (CMD_ESP_UART), see kg_mcu_esp
	parameter ENABLE_PS2_CMD = 0,   // CMD_PS2_SCANCODE to mcu (Next186 kbd/mouse control)
	parameter ENABLE_FLASHBOOT = 0, // CMD_FLASHBOOT to the mcu (next: the reload of a core), see port 9
	parameter ENABLE_MIDI = 0       // caps bit 4: MIDI IN of a USB keyboard (CMD_MIDI), see kg_mcu_midi
) (
	input wire CLK,
	input wire N_RESET,

	// spi
	input wire MCU_MOSI,
	output wire MCU_MISO,
	input wire MCU_SCK,
	input wire MCU_SS,
	input wire MCU_SPI_FT_SS,
	input wire MCU_SPI_SD2_SS,
	input wire MCU_BURST_CS_N,
	output wire MCU_BURST_READY,

	// usb mouse
	output wire [7:0] MS_X,
	output wire [7:0] MS_Y,
	output wire [2:0] MS_B,
	output wire [3:0] MS_Z,
	output wire MS_UPD,

	// usb keyboard, ps/2 and xt scancodes
	output wire [7:0] KB_STATUS,
	output wire [7:0] KB_DAT0,
	output wire [7:0] KB_DAT1,
	output wire [7:0] KB_DAT2,
	output wire [7:0] KB_DAT3,
	output wire [7:0] KB_DAT4,
	output wire [7:0] KB_DAT5,
	output wire [7:0] KB_SCANCODE,
	output wire KB_SCANCODE_UPD,
	output wire [7:0] XT_SCANCODE,
	output wire XT_SCANCODE_UPD,
	/* verilator lint_off UNUSEDSIGNAL */
	input wire [15:0] PS2_COMMAND,
	input wire PS2_COMMAND_WR,
	/* verilator lint_on UNUSEDSIGNAL */

	// joysticks, buttons
	output wire [12:0] JOY_L,
	output wire [12:0] JOY_R,
	output wire [1:0] BTNS,

	// rtc
	input wire [7:0] RTC_A,
	input wire [7:0] RTC_DI,
	output wire [7:0] RTC_DO,
	input wire RTC_CS,
	input wire RTC_WR_N,

	// usb uart
	output wire [7:0] UART_RX_DATA,
	output wire [7:0] UART_RX_IDX,
	input wire [7:0] UART_TX_DATA,
	input wire UART_TX_WR,
	input wire UART_TX_MODE,
	input wire [7:0] UART_DLM,
	input wire [7:0] UART_DLL,
	input wire UART_DLM_WR,
	input wire UART_DLL_WR,

	// soft switches, osd
	output wire [15:0] SOFTSW_COMMAND,
	output wire [15:0] OSD_COMMAND,

	// rom loader (and the ioctl file loader with FILE_TO_ROM)
	output wire ROMLOADER_ACTIVE,
	output wire [31:0] ROMLOAD_ADDR,
	output wire [7:0] ROMLOAD_DATA,
	output wire ROMLOAD_WR,
	output wire IOCTL_ACTIVE,

	// file loader (FILE_TO_ROM 0)
	output wire FILELOAD_RESET,
	output wire FILELOAD_ACTIVE,
	output wire [31:0] FILELOAD_SIZE,
	output wire [31:0] FILELOAD_ADDR,
	output wire [7:0] FILELOAD_DATA,
	output wire FILELOAD_WR,
	output wire [7:0] FILELOAD_SLOT, // the slot of the FL item of the file (FILE_CMDS 0), from IOCTL_SLOT

	// ft812
	output wire FT_SPI_ON,
	output wire FT_VGA_ON,
	output wire FT_RESET,
	output wire FT_SCK,
	output wire FT_MOSI,
	input wire FT_MISO,
	output wire FT_CS_N,

	// sd2
	output wire SD2_SCK,
	output wire SD2_MOSI,
	input wire SD2_MISO,
	output wire SD2_CS_N,

	// to the mcu: dot matrix / audio peaks, debug values
	// (the inputs of the features that are off are not used)
	/* verilator lint_off UNUSEDSIGNAL */
	input wire [23:0] MATRIX_CMD,
	input wire MATRIX_CMD_WR,
	input wire [15:0] DEBUG_ADDR,
	input wire [15:0] DEBUG_DATA,
	/* verilator lint_on UNUSEDSIGNAL */

	// hw setup
	output wire [7:0] HWID,
	output wire DVI_ONLY,

	// file mounter
	output wire [7:0] IMG_MOUNTED,
	output wire [63:0] IMG_SIZE,
	output wire IMG_DATA_WR,
	output wire [8:0] IMG_DATA_ADDR,
	output wire [7:0] IMG_DATA,
	output wire IMG_RESULT_WR,
	output wire [7:0] IMG_RESULT,
	output wire [15:0] IMG_SUM,
	/* verilator lint_off UNUSEDSIGNAL */
	input wire IMG_Q_WR,
	input wire [23:0] IMG_Q_DI,
	/* verilator lint_on UNUSEDSIGNAL */
	output wire IMG_Q_ACK,
	output wire IMG_PHYS_WR,
	output wire [15:0] IMG_PHYS,
	output wire [7:0] IMG_FLUSH,    // CMD_IMG_FLUSH of the mcu for slot n, one clock (kg_bk_ram)

	// esp8266 uart bridge: a byte to the esp (one clock), a byte from it (held until the ack)
	output wire [7:0] ESP_UART_TX_DATA,
	output wire ESP_UART_TX_WR,
	/* verilator lint_off UNUSEDSIGNAL */
	input wire [7:0] ESP_UART_RX_DATA,
	input wire ESP_UART_RX_WR,
	/* verilator lint_on UNUSEDSIGNAL */
	output wire ESP_UART_RX_ACK,

	// flashboot: a rising FLASHBOOT_START asks the mcu to load the core FLASHBOOT_COREID
	/* verilator lint_off UNUSEDSIGNAL */
	input wire FLASHBOOT_START,
	input wire [4:0] FLASHBOOT_COREID,
	/* verilator lint_on UNUSEDSIGNAL */

	// midi in (usb keyboard): a byte, one clock; lost: one clock with the byte after a gap
	output wire [7:0] MIDI_DATA,
	output wire MIDI_WR,
	output wire MIDI_LOST,

	output wire BUSY
);

// ---------------- link ----------------

`include "kg_mcu_cmds.vh"

localparam P = 11;
wire [P-1:0] tx_req;
wire [P*24-1:0] tx_data;
/* verilator lint_off UNUSEDSIGNAL */
wire [P-1:0] tx_grant;  // used by debug, img, esp and flashboot
wire tx_full;
/* verilator lint_on UNUSEDSIGNAL */

wire rx_stb, bst_wr;
wire [7:0] rx_cmd, rx_addr, rx_data, bst_type, bst_data;
wire [31:0] bst_addr;
wire spi_miso, spi_sel;

kg_mcu_link #(.BURST_MAX_MHZ(BURST_MAX_MHZ), .CS_FILTER(CS_FILTER), .CAPS_BK(ENABLE_BK), .CAPS_MIDI(ENABLE_MIDI), .TX_PORTS(P)) u_link(
	.clk(CLK), .reset(~N_RESET),
	.sck(MCU_SCK), .mosi(MCU_MOSI), .miso(spi_miso), .miso_en(spi_sel),
	.cs_n(MCU_SS), .burst_cs_n(MCU_BURST_CS_N), .burst_ready(MCU_BURST_READY),
	.rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
	.bst_wr(bst_wr), .bst_type(bst_type), .bst_addr(bst_addr), .bst_data(bst_data),
	.tx_req(tx_req), .tx_data(tx_data), .tx_grant(tx_grant), .tx_full(tx_full)
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

// ---------------- decoders ----------------

kg_mcu_ctl u_ctl(
	.clk(CLK), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
	.softsw_command(SOFTSW_COMMAND), .osd_command(OSD_COMMAND), .hwid(HWID), .dvi_only(DVI_ONLY),
	.btns(BTNS), .ft_spi_on(FT_SPI_ON), .ft_vga_on(FT_VGA_ON), .ft_reset(FT_RESET), .busy(BUSY)
);

wire [55:0] kb;
kg_mcu_hid u_hid(
	.clk(CLK), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
	.kb(kb), .ms_x(MS_X), .ms_y(MS_Y), .ms_z(MS_Z), .ms_b(MS_B), .ms_upd(MS_UPD), .ms_stb(),
	.joy_l(JOY_L), .joy_r(JOY_R),
	.kb_scancode(KB_SCANCODE), .kb_scancode_upd(KB_SCANCODE_UPD),
	.xt_scancode(XT_SCANCODE), .xt_scancode_upd(XT_SCANCODE_UPD)
);
assign { KB_DAT5, KB_DAT4, KB_DAT3, KB_DAT2, KB_DAT1, KB_DAT0, KB_STATUS } = kb;

kg_mcu_loader #(.ENABLE_FILE(ENABLE_FILE), .FILE_CMDS(FILE_CMDS), .FILE_WR_EACH(FILE_WR_EACH), .FILE_TO_ROM(FILE_TO_ROM)) u_loader(
	.clk(CLK), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
	.bst_wr(bst_wr), .bst_type(bst_type), .bst_addr(bst_addr), .bst_data(bst_data),
	.rom_active(ROMLOADER_ACTIVE), .rom_addr(ROMLOAD_ADDR), .rom_data(ROMLOAD_DATA), .rom_wr(ROMLOAD_WR),
	.file_reset(FILELOAD_RESET), .file_active(FILELOAD_ACTIVE), .file_size(FILELOAD_SIZE),
	.file_addr(FILELOAD_ADDR), .file_data(FILELOAD_DATA), .file_wr(FILELOAD_WR), .file_slot(FILELOAD_SLOT)
);
assign IOCTL_ACTIVE = FILELOAD_ACTIVE;

// midi in: no transmit port
generate
	if (ENABLE_MIDI) begin : kg_mcu_midi_on
		kg_mcu_midi u_midi(
			.clk(CLK), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
			.midi_data(MIDI_DATA), .midi_wr(MIDI_WR), .midi_lost(MIDI_LOST)
		);
	end
	else begin : kg_mcu_midi_off
		assign MIDI_DATA = 8'd0;
		assign MIDI_WR = 1'b0;
		assign MIDI_LOST = 1'b0;
	end
endgenerate

// uart: ports 0-2
generate
	if (ENABLE_UART) begin : kg_mcu_uart_on
		kg_mcu_uart u_uart(
			.clk(CLK), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
			.uart_rx_data(UART_RX_DATA), .uart_rx_idx(UART_RX_IDX),
			.uart_tx_data(UART_TX_DATA), .uart_tx_wr(UART_TX_WR), .uart_tx_mode(UART_TX_MODE),
			.uart_dll(UART_DLL), .uart_dll_wr(UART_DLL_WR), .uart_dlm(UART_DLM), .uart_dlm_wr(UART_DLM_WR),
			.tx_req(tx_req[2:0]), .tx_data(tx_data[0 +: 72])
		);
	end
	else begin : kg_mcu_uart_off
		assign UART_RX_DATA = 8'd0;
		assign UART_RX_IDX = 8'd0;
		assign tx_req[2:0] = 3'b000;
		assign tx_data[0 +: 72] = 72'd0;
	end
endgenerate

// rtc: port 3
generate
	if (ENABLE_RTC) begin : kg_mcu_rtc_on
		kg_mcu_rtc #(.SKIP_0D(RTC_SKIP_0D), .SEND_LIMIT(RTC_SEND_LIMIT)) u_rtc(
			.clk(CLK), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data), .busy(BUSY),
			.rtc_a(RTC_A), .rtc_di(RTC_DI), .rtc_do(RTC_DO), .rtc_cs(RTC_CS), .rtc_wr_n(RTC_WR_N),
			.tx_req(tx_req[3]), .tx_data(tx_data[3*24 +: 24])
		);
	end
	else begin : kg_mcu_rtc_off
		assign RTC_DO = 8'd0;
		assign tx_req[3] = 1'b0;
		assign tx_data[3*24 +: 24] = 24'd0;
	end
endgenerate

// matrix / audio peaks: port 4, the word as it is
assign tx_req[4] = ENABLE_MATRIX ? MATRIX_CMD_WR : 1'b0;
assign tx_data[4*24 +: 24] = MATRIX_CMD;

// debug: ports 5, 6
generate
	if (ENABLE_DEBUG) begin : kg_mcu_debug_on
		kg_mcu_debug u_debug(
			.clk(CLK), .debug_addr(DEBUG_ADDR), .debug_data(DEBUG_DATA),
			.tx_req(tx_req[6:5]), .tx_data(tx_data[5*24 +: 48]), .tx_grant(tx_grant[6:5])
		);
	end
	else begin : kg_mcu_debug_off
		assign tx_req[6:5] = 2'b00;
		assign tx_data[5*24 +: 48] = 48'd0;
	end
endgenerate

// file mounter: port 7
generate
	if (ENABLE_IMG) begin : kg_mcu_img_on
		kg_mcu_img u_img(
			.clk(CLK), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
			.bst_wr(bst_wr), .bst_type(bst_type), .bst_addr(bst_addr), .bst_data(bst_data),
			.img_mounted(IMG_MOUNTED), .img_size(IMG_SIZE), .img_data_wr(IMG_DATA_WR),
			.img_data_addr(IMG_DATA_ADDR), .img_data(IMG_DATA), .img_result_wr(IMG_RESULT_WR),
			.img_result(IMG_RESULT), .img_sum(IMG_SUM), .img_phys_wr(IMG_PHYS_WR), .img_phys(IMG_PHYS), .img_flush(IMG_FLUSH),
			.img_q_wr(IMG_Q_WR), .img_q_di(IMG_Q_DI), .img_q_ack(IMG_Q_ACK),
			.tx_req(tx_req[7]), .tx_data(tx_data[7*24 +: 24]), .tx_grant(tx_grant[7]), .tx_full(tx_full)
		);
	end
	else begin : kg_mcu_img_off
		assign IMG_MOUNTED = 8'd0;
		assign IMG_SIZE = 64'd0;
		assign IMG_DATA_WR = 1'b0;
		assign IMG_DATA_ADDR = 9'd0;
		assign IMG_DATA = 8'd0;
		assign IMG_RESULT_WR = 1'b0;
		assign IMG_RESULT = 8'd0;
		assign IMG_SUM = 16'd0;
		assign IMG_Q_ACK = 1'b0;
		assign IMG_PHYS_WR = 1'b0;
		assign IMG_PHYS = 16'd0;
		assign IMG_FLUSH = 8'd0;
		assign tx_req[7] = 1'b0;
		assign tx_data[7*24 +: 24] = 24'd0;
	end
endgenerate

// esp8266 uart bridge: port 8
generate
	if (ENABLE_ESP) begin : kg_mcu_esp_on
		kg_mcu_esp u_esp(
			.clk(CLK), .rx_stb(rx_stb), .rx_cmd(rx_cmd), .rx_addr(rx_addr), .rx_data(rx_data),
			.esp_tx_data(ESP_UART_TX_DATA), .esp_tx_wr(ESP_UART_TX_WR),
			.esp_rx_data(ESP_UART_RX_DATA), .esp_rx_wr(ESP_UART_RX_WR), .esp_rx_ack(ESP_UART_RX_ACK),
			.tx_req(tx_req[8]), .tx_data(tx_data[8*24 +: 24]), .tx_grant(tx_grant[8]), .tx_full(tx_full)
		);
	end
	else begin : kg_mcu_esp_off
		assign ESP_UART_TX_DATA = 8'd0;
		assign ESP_UART_TX_WR = 1'b0;
		assign ESP_UART_RX_ACK = 1'b0;
		assign tx_req[8] = 1'b0;
		assign tx_data[8*24 +: 24] = 24'd0;
	end
endgenerate

// flashboot: port 9. The mcu.vhd of next put CMD_FLASHBOOT in the queue in every clock while
// FLASHBOOT_START was high (and not busy), ahead of every other source, so the queue was full of
// them until the mcu reloaded the fpga; one word does the same. A rising FLASHBOOT_START is kept
// until the word goes in: not while BUSY (as mcu.vhd), not into a full queue.
generate
	if (ENABLE_FLASHBOOT) begin : kg_mcu_flashboot_on
		reg fb_prev = 1'b0, fb_pend = 1'b0;
		always @(posedge CLK) begin
			fb_prev <= FLASHBOOT_START;
			if (FLASHBOOT_START && !fb_prev)
				fb_pend <= 1'b1;
			else if (tx_grant[9])
				fb_pend <= 1'b0;
		end
		assign tx_req[9] = fb_pend && !BUSY && !tx_full;
		assign tx_data[9*24 +: 24] = { CMD_FLASHBOOT, 8'h00, 3'b000, FLASHBOOT_COREID };
	end
	else begin : kg_mcu_flashboot_off
		assign tx_req[9] = 1'b0;
		assign tx_data[9*24 +: 24] = 24'd0;
	end
endgenerate

generate
	if (ENABLE_PS2_CMD) begin : kg_mcu_ps2_cmd_on
		assign tx_req[10] = PS2_COMMAND_WR;
		assign tx_data[10*24 +: 24] = { CMD_PS2_SCANCODE, PS2_COMMAND };
	end
	else begin : kg_mcu_ps2_cmd_off
		assign tx_req[10] = 1'b0;
		assign tx_data[10*24 +: 24] = 24'd0;
	end
endgenerate

endmodule
