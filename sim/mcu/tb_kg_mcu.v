`timescale 1ns / 1ps

// kg_mcu.v beyond what mcu.vhd of nanomig has (tb_eq_mcu compares that part), iverilog. Six
// instances on one spi bus, replies read from the one selected:
//   ts  tsconf: ps/2 and xt scancodes, uart mode / dll / dlm, debug values, FT_RESET, rtc
//       registers D sent and F0-FF not, no file loader;
//   rk  rk86 / spec256: ioctl file loader on its own signals, a write per address change;
//   alf alf / nes: the file commands 0C-0E;
//   nm  nanomig: a full reply queue holds a file mounter word until there is room;
//   esp menu: the ESP8266 uart bridge, bytes both ways, a byte from the ESP held while the reply
//       queue is full; MIDI IN (CMD_MIDI, caps bit 4), a gap in the byte counter;
//   nx  next: flashboot, one word per rising FLASHBOOT_START, held while BUSY.
// Also: the chip select filter (a short high spike in a frame; ts filters, rk does not), a frame
// decoded once (MS_UPD and the scancode flags toggle once).
// Ends with "tb_kg_mcu: N errors".

module tb_kg_mcu;

reg clk = 1'b0;
always #17.65 clk = ~clk;

integer errors = 0;
task fail(input [8*72-1:0] what);
	begin
		if (errors < 30) $display("%t ERROR: %0s", $time, what);
		errors = errors + 1;
	end
endtask

reg cs_n = 1'b1, sck = 1'b0, mosi = 1'b0, burst_cs_n = 1'b1;
reg [2:0] sel = 3'd0; // whose replies are read: 0 ts, 1 rk, 2 alf, 3 nm, 4 esp, 5 nx
wire [5:0] miso;
wire miso_sel = miso[sel];

// core side
reg [7:0] rtc_a = 8'h00, rtc_di = 8'h00;
reg rtc_cs = 1'b0, rtc_wr_n = 1'b1;
reg [7:0] uart_tx_data = 8'h00, uart_dll = 8'h00, uart_dlm = 8'h00;
reg uart_tx_wr = 1'b0, uart_tx_mode = 1'b0, uart_dll_wr = 1'b0, uart_dlm_wr = 1'b0;
reg [23:0] matrix_cmd = 24'h0;
reg matrix_cmd_wr = 1'b0;
reg [15:0] debug_addr = 16'h0000, debug_data = 16'h0000;
reg img_q_wr = 1'b0;
reg [23:0] img_q_di = 24'h0;
reg fb_start = 1'b0;
reg [4:0] fb_coreid = 5'd0;

`define INPUTS(i) \
	.CLK(clk), .N_RESET(1'b1), \
	.MCU_MOSI(mosi), .MCU_MISO(miso[i]), .MCU_SCK(sck), .MCU_SS(cs_n), \
	.MCU_SPI_FT_SS(1'b1), .MCU_SPI_SD2_SS(1'b1), .MCU_BURST_CS_N(burst_cs_n), \
	.RTC_A(rtc_a), .RTC_DI(rtc_di), .RTC_CS(rtc_cs), .RTC_WR_N(rtc_wr_n), \
	.UART_TX_DATA(uart_tx_data), .UART_TX_WR(uart_tx_wr), .UART_TX_MODE(uart_tx_mode), \
	.UART_DLM(uart_dlm), .UART_DLL(uart_dll), .UART_DLM_WR(uart_dlm_wr), .UART_DLL_WR(uart_dll_wr), \
	.FT_MISO(1'b1), .SD2_MISO(1'b1), \
	.MATRIX_CMD(matrix_cmd), .MATRIX_CMD_WR(matrix_cmd_wr), .DEBUG_ADDR(debug_addr), .DEBUG_DATA(debug_data), \
	.IMG_Q_WR(img_q_wr), .IMG_Q_DI(img_q_di), .FLASHBOOT_START(fb_start), .FLASHBOOT_COREID(fb_coreid)

// tsconf
wire ts_ms_upd, ts_kb_upd, ts_xt_upd, ts_ft_spi, ts_ft_vga, ts_ft_reset, ts_busy;
wire [7:0] ts_kb_sc, ts_xt_sc;
wire [15:0] ts_softsw;
wire [63:0] ts_core_build, ts_fw_build;
kg_mcu #(.CS_FILTER(3), .RTC_SKIP_0D(0), .RTC_SEND_LIMIT('hF0), .ENABLE_DEBUG(1), .ENABLE_IMG(0),
	.ENABLE_FILE(0), .ENABLE_SD2(0)) ts(`INPUTS(0),
	.MS_UPD(ts_ms_upd), .KB_SCANCODE(ts_kb_sc), .KB_SCANCODE_UPD(ts_kb_upd), .XT_SCANCODE(ts_xt_sc),
	.XT_SCANCODE_UPD(ts_xt_upd), .FT_SPI_ON(ts_ft_spi), .FT_VGA_ON(ts_ft_vga), .FT_RESET(ts_ft_reset),
	.SOFTSW_COMMAND(ts_softsw), .BUSY(ts_busy), .CORE_BUILD(ts_core_build), .FW_BUILD(ts_fw_build));

// rk86 / spec256 (no chip select filter: the spike test shows what it is for)
wire rk_reset, rk_active, rk_wr, rk_romwr;
wire [31:0] rk_size, rk_addr;
wire [7:0] rk_data, rk_slot;
wire [15:0] rk_softsw;
kg_mcu #(.CS_FILTER(0), .ENABLE_FILE(1), .FILE_CMDS(0), .FILE_WR_EACH(0), .FILE_TO_ROM(0)) rk(`INPUTS(1),
	.FILELOAD_RESET(rk_reset), .FILELOAD_ACTIVE(rk_active), .FILELOAD_SIZE(rk_size),
	.FILELOAD_ADDR(rk_addr), .FILELOAD_DATA(rk_data), .FILELOAD_WR(rk_wr), .FILELOAD_SLOT(rk_slot), .ROMLOAD_WR(rk_romwr),
	.SOFTSW_COMMAND(rk_softsw));

// alf / nes
wire alf_reset, alf_active, alf_wr;
wire [31:0] alf_addr;
wire [7:0] alf_data;
kg_mcu #(.ENABLE_FILE(1), .FILE_CMDS(1), .FILE_WR_EACH(0), .FILE_TO_ROM(0)) alf(`INPUTS(2),
	.FILELOAD_RESET(alf_reset), .FILELOAD_ACTIVE(alf_active), .FILELOAD_ADDR(alf_addr),
	.FILELOAD_DATA(alf_data), .FILELOAD_WR(alf_wr));

// nanomig
wire nm_ack, nm_chng_wr;
wire [15:0] nm_chng;
reg chng_req = 1'b0;
reg [1:0] chng_ds = 2'd0;
kg_mcu #(.BURST_MAX_MHZ(32), .ENABLE_IMG(1), .ENABLE_FDD_CHNG(1)) nm(`INPUTS(3), .IMG_Q_ACK(nm_ack),
	.FDD_CHNG_REQ(chng_req), .FDD_CHNG_DS(chng_ds), .FDD_CHNG_WR(nm_chng_wr), .FDD_CHNG(nm_chng));
// the same requests on the tsconf instance (no ENABLE_IMG) and an IMG one without ENABLE_FDD_CHNG
wire ts_chng_wr = ts.FDD_CHNG_WR;
integer chng_n = 0, ts_chng_n = 0;
reg [15:0] chng_last = 16'h0;
always @(posedge clk) begin
	if (nm_chng_wr) begin chng_n <= chng_n + 1; chng_last <= nm_chng; end
	if (ts_chng_wr) ts_chng_n <= ts_chng_n + 1;
end

// menu: the ESP uart bridge, nothing that answers but CAPS
reg [7:0] esp_rx_data = 8'h00;
reg esp_rx_wr = 1'b0;
wire [7:0] esp_tx_data;
wire esp_tx_wr, esp_rx_ack, ts_esp_tx_wr;
wire [7:0] midi_data;
wire midi_wr, midi_lost;
kg_mcu #(.ENABLE_RTC(0), .ENABLE_UART(0), .ENABLE_MATRIX(0), .ENABLE_FILE(0), .ENABLE_SD2(0), .ENABLE_ESP(1),
	.ENABLE_MIDI(1))
	esp(`INPUTS(4), .ESP_UART_TX_DATA(esp_tx_data), .ESP_UART_TX_WR(esp_tx_wr),
	.ESP_UART_RX_DATA(esp_rx_data), .ESP_UART_RX_WR(esp_rx_wr), .ESP_UART_RX_ACK(esp_rx_ack),
	.MIDI_DATA(midi_data), .MIDI_WR(midi_wr), .MIDI_LOST(midi_lost));
assign ts_esp_tx_wr = ts.ESP_UART_TX_WR;

// midi bytes of the menu, and of tsconf (no ENABLE_MIDI)
reg [7:0] midi_log [0:15];
integer midi_n = 0, midi_lost_n = 0, ts_midi_n = 0;
always @(posedge clk) begin
	if (midi_wr) begin
		if (midi_n < 16) midi_log[midi_n] <= midi_data;
		midi_n <= midi_n + 1;
	end
	if (midi_lost) midi_lost_n <= midi_lost_n + 1;
	if (ts.MIDI_WR) ts_midi_n <= ts_midi_n + 1;
end

// next: flashboot, rtc, matrix
wire nx_busy;
kg_mcu #(.ENABLE_UART(0), .ENABLE_FILE(0), .ENABLE_FT(0), .ENABLE_SD2(0), .ENABLE_FLASHBOOT(1))
	nx(`INPUTS(5), .BUSY(nx_busy));

// ---------------- mcu model ----------------

task spi_byte(input [7:0] tx, output [7:0] rx);
	integer k;
	begin
		for (k = 7; k >= 0; k = k - 1) begin
			mosi = tx[k];
			#31;
			sck = 1'b1;
			rx[k] = miso_sel;
			#31;
			sck = 1'b0;
		end
	end
endtask

reg [23:0] rxq [0:4095];
integer rx_n = 0, rx_rd = 0;
reg [7:0] rc, ra, rd;
reg glitch = 1'b0; // a 50 ns high spike on cs_n in the middle of the second byte
task frame(input [7:0] c, input [7:0] a, input [7:0] d);
	begin
		cs_n = 1'b0;
		#100;
		spi_byte(c, rc);
		if (glitch) fork
			spi_byte(a, ra);
			begin #250; cs_n = 1'b1; #50; cs_n = 1'b0; end
		join
		else
			spi_byte(a, ra);
		spi_byte(d, rd);
		#50;
		cs_n = 1'b1;
		#500;
		if (rc !== 8'hFF) begin
			rxq[rx_n] = { rc, ra, rd };
			rx_n = rx_n + 1;
		end
	end
endtask

task expect_reply(input [23:0] w);
	integer n;
	begin
		n = 0;
		while (rx_rd == rx_n && n < 20) begin frame(8'hFF, 8'h00, 8'h00); n = n + 1; end
		if (rx_rd == rx_n) begin
			$display("%t ERROR: no reply, expected %h", $time, w);
			errors = errors + 1;
		end
		else begin
			if (rxq[rx_rd] !== w) begin
				$display("%t ERROR: reply %h, expected %h", $time, rxq[rx_rd], w);
				errors = errors + 1;
			end
			rx_rd = rx_rd + 1;
		end
	end
endtask

task expect_no_reply;
	integer n;
	begin
		for (n = 0; n < 6; n = n + 1) frame(8'hFF, 8'h00, 8'h00);
		while (rx_rd != rx_n) begin
			$display("%t ERROR: unexpected reply %h", $time, rxq[rx_rd]);
			errors = errors + 1;
			rx_rd = rx_rd + 1;
		end
	end
endtask

task flush; // drop what is queued
	integer n;
	begin
		for (n = 0; n < 6; n = n + 1) frame(8'hFF, 8'h00, 8'h00);
		rx_rd = rx_n;
	end
endtask

task burst(input [7:0] t, input [31:0] addr, input integer n, input [7:0] base);
	integer k;
	reg [7:0] dummy;
	begin
		burst_cs_n = 1'b0;
		#100;
		spi_byte(t, dummy);
		spi_byte(addr[31:24], dummy);
		spi_byte(addr[23:16], dummy);
		spi_byte(addr[15:8], dummy);
		spi_byte(addr[7:0], dummy);
		for (k = 0; k < n; k = k + 1) spi_byte(base + k, dummy);
		#100;
		burst_cs_n = 1'b1;
		#500;
	end
endtask

task strobe_uart(input mode, input [7:0] d);
	begin
		@(negedge clk);
		uart_tx_data = d; uart_tx_mode = mode; uart_tx_wr = 1'b1;
		@(negedge clk);
		uart_tx_wr = 1'b0;
	end
endtask

task host_rtc_write(input [7:0] a, input [7:0] d);
	begin
		@(negedge clk);
		rtc_a = a; rtc_di = d; rtc_cs = 1'b1; rtc_wr_n = 1'b0;
		@(negedge clk);
		rtc_cs = 1'b0; rtc_wr_n = 1'b1;
	end
endtask

// ---------------- monitors ----------------

integer ts_ms_tg = 0, ts_kb_tg = 0, ts_xt_tg = 0;
reg ts_ms_p = 1'b0, ts_kb_p = 1'b0, ts_xt_p = 1'b0;
always @(posedge clk) begin
	if (ts_ms_upd !== ts_ms_p) ts_ms_tg = ts_ms_tg + 1;
	if (ts_kb_upd !== ts_kb_p) ts_kb_tg = ts_kb_tg + 1;
	if (ts_xt_upd !== ts_xt_p) ts_xt_tg = ts_xt_tg + 1;
	ts_ms_p = ts_ms_upd; ts_kb_p = ts_kb_upd; ts_xt_p = ts_xt_upd;
end

integer acks = 0;
always @(posedge clk) if (nm_ack) acks = acks + 1;

// esp: bytes to the ESP; the ESP side puts up esp_send bytes 0, 1, ... (+ esp_base), each held
// until its ack, the next one in the clock of the ack
reg [7:0] esp_log [0:15];
integer esp_tx_n = 0, ts_esp_n = 0, esp_send = 0, esp_sent = 0, esp_acks_full = 0;
reg [7:0] esp_base = 8'h00;
reg esp_full_check = 1'b0;
always @(posedge clk) begin
	if (esp_tx_wr) begin esp_log[esp_tx_n % 16] = esp_tx_data; esp_tx_n = esp_tx_n + 1; end
	if (ts_esp_tx_wr) ts_esp_n = ts_esp_n + 1;
	if (esp_rx_ack && esp_full_check && esp.u_link.u_queue.count == 512) esp_acks_full = esp_acks_full + 1;
end
always @(negedge clk) begin
	if (esp_rx_wr && esp_rx_ack)
		esp_sent = esp_sent + 1;
	esp_rx_wr = esp_sent < esp_send;
	esp_rx_data = esp_base + esp_sent[7:0];
end

reg [39:0] rk_log [0:255], alf_log [0:255];
integer rk_n = 0, alf_n = 0, rk_resets = 0, rk_romwrs = 0;
always @(posedge clk) begin
	if (rk_wr) begin rk_log[rk_n] = { rk_addr, rk_data }; rk_n = rk_n + 1; end
	if (alf_wr) begin alf_log[alf_n] = { alf_addr, alf_data }; alf_n = alf_n + 1; end
	if (rk_reset) rk_resets = rk_resets + 1;
	if (rk_romwr) rk_romwrs = rk_romwrs + 1;
end

// ---------------- test ----------------

integer i, n0, n1;
initial begin
	#1000;
	flush;
	frame(8'hFE, 8'h00, 8'h00); // INIT_DONE
	if (ts_busy !== 1'b0) fail("BUSY");

	// ---- tsconf: a report toggles MS_UPD once, scancodes ----
	frame(8'h02, 8'h03, 8'h01);
	frame(8'h0B, 8'h00, 8'h1C);
	frame(8'h0B, 8'h01, 8'h9C);
	if (ts_ms_tg != 1 || ts_kb_tg != 1 || ts_xt_tg != 1) fail("MS_UPD / scancode flags not toggled once per frame");
	if (ts_kb_sc !== 8'h1C || ts_xt_sc !== 8'h9C) fail("scancodes");

	// ---- tsconf: CONTROL with FT_RESET ----
	frame(8'h09, 8'h00, 8'h13);
	if ({ ts_ft_spi, ts_ft_vga, ts_ft_reset } !== 3'b111) fail("CONTROL 13");
	frame(8'h09, 8'h00, 8'h00);
	if ({ ts_ft_spi, ts_ft_vga, ts_ft_reset } !== 3'b000) fail("CONTROL 00");

	// ---- HW_SETUP 10..1F: build ids of the core and the firmware, character 0 in the top byte ----
	if (ts_core_build !== 64'd0 || ts_fw_build !== 64'd0) fail("build ids not 0 before HW_SETUP 10..1F");
	for (i = 0; i < 8; i = i + 1) begin
		frame(8'hF9, 8'h10 + i, "26110102" >> (8 * (7 - i)));
		frame(8'hF9, 8'h18 + i, i < 6 ? "DEVBLD" >> (8 * (5 - i)) : 8'h00);
	end
	if (ts_core_build !== "26110102") fail("CORE_BUILD");
	if (ts_fw_build !== { "DEVBLD", 16'h0000 }) fail("FW_BUILD (0 padded)");

	// ---- tsconf: uart modes and divisor ----
	flush;
	strobe_uart(1'b0, 8'h41);
	strobe_uart(1'b1, 8'h42);
	@(negedge clk); uart_dll = 8'h0C; uart_dll_wr = 1'b1; @(negedge clk); uart_dll_wr = 1'b0;
	@(negedge clk); uart_dlm = 8'h01; uart_dlm_wr = 1'b1; @(negedge clk); uart_dlm_wr = 1'b0;
	expect_reply(24'hFC_00_41);
	expect_reply(24'hFC_03_42);
	expect_reply(24'hFC_01_0C);
	expect_reply(24'hFC_02_01);
	expect_no_reply;

	// ---- tsconf: debug values; both at once, and with a uart byte in the same clock ----
	@(negedge clk); debug_addr = 16'h1234; debug_data = 16'h5678; uart_tx_data = 8'h43; uart_tx_mode = 0; uart_tx_wr = 1'b1;
	@(negedge clk); uart_tx_wr = 1'b0;
	expect_reply(24'hFC_00_43);
	expect_reply(24'h30_1234);
	expect_reply(24'h31_5678);
	expect_no_reply;
	@(negedge clk); debug_data = 16'h9ABC;
	expect_reply(24'h31_9ABC);
	expect_no_reply;

	// ---- tsconf: rtc registers to the mcu: D yes, C no, F0 up no ----
	host_rtc_write(8'h0D, 8'h80);
	host_rtc_write(8'h0C, 8'h40);
	host_rtc_write(8'hF0, 8'h01);
	host_rtc_write(8'hEF, 8'h02);
	expect_reply(24'hFA_0D_80);
	expect_reply(24'hFA_EF_02);
	expect_no_reply;

	// ---- rk86 / spec256: ioctl on FILELOAD_*, a write per address change ----
	frame(8'h50, 8'h00, 8'h01);                         // slot: FILELOAD_RESET
	if (rk_resets != 1) fail("FILELOAD_RESET pulses");
	if (rk_slot !== 8'h01) fail("FILELOAD_SLOT 1");
	for (i = 0; i < 4; i = i + 1) frame(8'h51, i, 8'h10 * (i + 1));
	if (rk_size !== 32'h40302010) fail("FILELOAD_SIZE");
	frame(8'h55, 8'h00, 8'h01);
	if (rk_active !== 1'b1) fail("FILELOAD_ACTIVE");
	frame(8'h52, 8'h00, 8'h02);
	frame(8'h52, 8'h01, 8'h00);
	frame(8'h52, 8'h02, 8'h00);
	frame(8'h53, 8'h00, 8'hA0);
	frame(8'h53, 8'h01, 8'hA1);
	frame(8'h53, 8'h01, 8'hA2);                         // the same address: not written
	burst(8'h53, 32'h00000300, 4, 8'hB0);
	// the file commands of alf and the rom loader do not touch these
	frame(8'h0E, 8'h00, 8'h03);
	frame(8'h0D, 8'h05, 8'hEE);
	if (rk_n != 6) begin $display("%t ERROR: rk86 file writes %0d, expected 6", $time, rk_n); errors = errors + 1; end
	if (rk_log[0] !== 40'h00000200_A0 || rk_log[1] !== 40'h00000201_A1 || rk_log[2] !== 40'h00000300_B0 ||
	    rk_log[5] !== 40'h00000303_B3) fail("rk86 file writes");
	if (rk_romwrs != 0) fail("rk86 rom writes from the file loader");

	// ---- alf: FILELOADER levels, FILEBANK / FILEDATA ----
	if (alf_reset !== 1'b1 || alf_active !== 1'b1) fail("alf FILELOADER 03");
	frame(8'h0C, 8'h00, 8'h00);
	frame(8'h0C, 8'h01, 8'h01);
	frame(8'h0C, 8'h02, 8'h00);
	frame(8'h0D, 8'h07, 8'hC7);
	burst(8'h0D, 32'h00020010, 2, 8'hD0);
	frame(8'h0E, 8'h00, 8'h00);
	if (alf_reset !== 1'b0 || alf_active !== 1'b0) fail("alf FILELOADER 00");
	// alf saw 0D 05 EE above (address 0000_0005) and these three
	if (alf_n != 4 || alf_log[1] !== 40'h00010007_C7 || alf_log[3] !== 40'h00020011_D1) fail("alf file writes");

	// ---- chip select filter: a 50 ns high spike in a frame ----
	glitch = 1'b1;
	frame(8'h05, 8'h12, 8'h34);
	glitch = 1'b0;
	if (ts_softsw !== 16'h1234) fail("frame with a cs spike lost with the filter");
	if (rk_softsw === 16'h1234) fail("frame with a cs spike taken without the filter (the test does not test)");
	frame(8'h05, 8'h00, 8'h00);

	// ---- nanomig: a full reply queue ----
	// 520 matrix words without a frame: the queue fills at 512 (a NOPE may be first in it)
	@(negedge clk);
	for (i = 0; i < 520; i = i + 1) begin
		matrix_cmd = { 8'h70, i[15:0] }; matrix_cmd_wr = 1'b1;
		@(negedge clk);
	end
	matrix_cmd_wr = 1'b0;
	if (nm.u_link.u_queue.count != 512) fail("queue not full at 512");
	// a file mounter word waits while it is full: no ack (a word acked then would be lost)
	img_q_di = 24'h43_00_01; img_q_wr = 1'b1;
	acks = 0;
	repeat (20) @(negedge clk);
	if (acks != 0) fail("IMG_Q_ACK while the queue is full");
	sel = 2'd3;
	n0 = rx_n;
	frame(8'hFF, 8'h00, 8'h00);                         // takes a word: room for one
	repeat (10) @(negedge clk);
	img_q_wr = 1'b0;
	if (acks != 1 || nm.u_link.u_queue.count != 512) fail("file mounter word not taken once after a pop");
	// out in order: matrix words 0, 1, ... (510 or 511 of them), then the file mounter word
	for (i = 0; i < 516; i = i + 1) frame(8'hFF, 8'h00, 8'h00);
	n1 = 0;
	while (n0 + n1 < rx_n && rxq[n0 + n1] === { 8'h70, n1[15:0] }) n1 = n1 + 1;
	if (n1 < 510 || rxq[n0 + n1] !== 24'h43_00_01 || n0 + n1 + 1 != rx_n) begin
		$display("%t ERROR: after the full queue: %0d matrix words in order, then %h, %0d words in all",
			$time, n1, rxq[n0 + n1], rx_n - n0);
		errors = errors + 1;
	end
	sel = 3'd0;

	// ---- nanomig: DSKCHG request / answer (CMD_FDD_CHNG 49) ----
	sel = 3'd3;
	flush;
	@(negedge clk); chng_ds = 2'd1; chng_req = 1'b1; @(negedge clk); chng_req = 1'b0;
	expect_reply(24'h49_01_00);
	expect_no_reply;
	// a request waiting next to a file mounter word: the request first, then the word, each once
	acks = 0;
	@(negedge clk); chng_ds = 2'd2; chng_req = 1'b1;
	@(negedge clk); chng_req = 1'b0; img_q_di = 24'h43_00_01; img_q_wr = 1'b1;
	while (acks == 0) @(negedge clk);
	img_q_wr = 1'b0;
	expect_reply(24'h49_02_00);
	expect_reply(24'h43_00_01);
	expect_no_reply;
	if (acks != 1) fail("file mounter word acked more than once next to a DSKCHG request");
	// the answer of the mcu
	frame(8'h49, 8'h01, 8'h01);
	frame(8'h49, 8'h02, 8'h00);
	repeat (4) @(negedge clk);
	if (chng_n != 2 || chng_last !== 16'h0200) fail("DSKCHG answers");
	if (ts_chng_n != 0) fail("DSKCHG answer without ENABLE_IMG");
	sel = 3'd0;

	// ---- menu: the ESP uart bridge ----
	sel = 3'd4;
	flush;
	frame(8'hF8, 8'h00, 8'h41);
	frame(8'hF8, 8'h00, 8'h0D);
	if (esp_tx_n != 2 || esp_log[0] !== 8'h41 || esp_log[1] !== 8'h0D) fail("bytes to the ESP");
	if (ts_esp_n != 0) fail("ESP bytes without ENABLE_ESP");
	esp_base = 8'h30; esp_sent = 0; esp_send = 3;
	expect_reply(24'hF8_00_30);
	expect_reply(24'hF8_00_31);
	expect_reply(24'hF8_00_32);
	expect_no_reply;
	// 600 bytes without a frame: the queue fills at 512 and the rest wait for room
	esp_base = 8'h00; esp_sent = 0; esp_full_check = 1'b1; esp_send = 600;
	repeat (2000) @(negedge clk);
	if (esp.u_link.u_queue.count != 512 || esp_sent < 510 || esp_sent > 512) begin
		$display("%t ERROR: esp: queue %0d words, %0d bytes sent while not read", $time,
			esp.u_link.u_queue.count, esp_sent);
		errors = errors + 1;
	end
	if (esp_acks_full != 0) fail("ESP byte acked while the queue was full");
	n0 = rx_n;
	for (i = 0; i < 620; i = i + 1) frame(8'hFF, 8'h00, 8'h00);
	esp_full_check = 1'b0;
	// out in order: a NOPE may be first in the queue, then the 600 bytes
	n1 = 0;
	while (n0 + n1 < rx_n && rxq[n0 + n1] === { 8'hF8, 8'h00, n1[7:0] }) n1 = n1 + 1;
	if (n1 != 600 || rx_n != n0 + 600) begin
		$display("%t ERROR: esp after the full queue: %0d bytes in order, %0d words in all", $time, n1, rx_n - n0);
		errors = errors + 1;
	end
	sel = 3'd0;

	// ---- menu: midi in ----
	sel = 3'd4;
	flush;
	frame(8'hF7, 8'h00, 8'h01);
	expect_reply(24'hF7_13_00);                         // caps: bursts + ready + midi
	frame(8'h16, 8'h00, 8'h90);
	frame(8'h16, 8'h01, 8'h3C);
	frame(8'h16, 8'h02, 8'h64);
	expect_no_reply;                                    // midi is mcu -> fpga only
	if (midi_n != 3 || midi_log[0] !== 8'h90 || midi_log[1] !== 8'h3C || midi_log[2] !== 8'h64)
		fail("midi bytes");
	if (midi_lost_n != 0) fail("midi lost without a gap");
	frame(8'h16, 8'h05, 8'h80);                         // bytes 3, 4 lost in the firmware
	frame(8'h16, 8'h06, 8'h3C);
	if (midi_n != 5 || midi_log[3] !== 8'h80 || midi_log[4] !== 8'h3C) fail("midi bytes after a gap");
	if (midi_lost_n != 1) fail("midi lost once after a gap");
	frame(8'h16, 8'hFF, 8'h00);                         // a gap again, then the counter wraps
	frame(8'h16, 8'h00, 8'h01);
	if (midi_lost_n != 2) fail("midi lost at the wrap");
	if (ts_midi_n != 0) fail("midi without ENABLE_MIDI");
	sel = 3'd0;
	frame(8'hF7, 8'h00, 8'h01);
	expect_reply(24'hF7_03_00);                         // tsconf: no caps bit 4
	flush;

	// ---- next: flashboot ----
	// mcu.vhd of next put the word in the queue in every clock while FLASHBOOT_START was high
	sel = 3'd5;
	flush;
	frame(8'hFD, 8'h00, 8'h00);                         // INIT_START: busy
	if (nx_busy !== 1'b1) fail("next BUSY");
	@(negedge clk); fb_coreid = 5'd1; fb_start = 1'b1;
	expect_no_reply;                                    // not while busy
	frame(8'hFE, 8'h00, 8'h00);                         // INIT_DONE
	expect_reply(24'hFB_00_01);
	expect_no_reply;                                    // one word, the start still high
	@(negedge clk); fb_start = 1'b0; fb_coreid = 5'd17;
	@(negedge clk); fb_start = 1'b1;
	@(negedge clk); fb_start = 1'b0;                    // a one clock start
	expect_reply(24'hFB_00_11);
	expect_no_reply;
	sel = 3'd0;
	@(negedge clk); fb_start = 1'b1;
	expect_no_reply;                                    // tsconf: no ENABLE_FLASHBOOT
	@(negedge clk); fb_start = 1'b0;

	$display("tb_kg_mcu: %0d errors", errors);
	$finish;
end

initial begin
	#200000000;
	$display("ERROR: timeout");
	$display("tb_kg_mcu: 1 errors");
	$finish;
end

endmodule
