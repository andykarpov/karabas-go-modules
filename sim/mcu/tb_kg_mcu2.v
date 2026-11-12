`timescale 1ns / 1ps

/*
 tb_kg_mcu2.v

 kg_mcu2 (link v2, karabas-go-firmware docs/link_v2.md) with a model of the mcu: packets in SPI
 mode 0 at SCK_HALF ns per half clock (16 MHz: 31, 32 MHz: 16), the core clock CLK_HALF, a gap
 of GAP ns between the bytes (0 = back to back, as a DMA transfer). Every target command of Ф2:
 SYS STATUS / IRQ / IRQ_SRC / SETVAL / HW_SETUP / INIT / SPI_CONTROL / BTN / RELOAD, HID KBD /
 PS2 / MOUSE / JOY / EVENT, LOAD START / DATA / END / STATUS, and INT. Prints
 "tb_kg_mcu2: 0 errors".
*/

module tb_kg_mcu2;

parameter CLK_HALF = 17.86; // 28 MHz
parameter SCK_HALF = 31;    // 16 MHz
parameter GAP = 0;

reg clk = 1'b0;
always #(CLK_HALF) clk = ~clk;

reg sck = 1'b0, mosi = 1'b0, ss = 1'b1;
wire miso, int_line;

integer errors = 0;

task check(input [255:0] what, input [63:0] got, input [63:0] want);
	if (got !== want) begin
		$display("ERROR %0s: got %h, want %h", what, got, want);
		errors = errors + 1;
	end
endtask

// ---------------- the core side ----------------

reg reload_req = 1'b0;
reg [15:0] ps2_cmd = 16'd0;
reg ps2_cmd_wr = 1'b0;
reg ld_ready = 1'b1;

wire [16*8-1:0] sw;
wire sw_wr, kbd_wr, ps2_wr, ps2_kind, ms_wr, joy_wr, busy, dvi_only;
wire [7:0] sw_index, sw_value, hw_id, ps2_code, ms_x, ms_y, ms_z, ms_b;
wire [63:0] core_build, fw_build;
wire [5:0] btns;
wire [55:0] kbd;
wire [15:0] joy_l, joy_r;
wire [1:0] ld_kind;
wire [7:0] ld_slot, ld_data;
wire [31:0] ld_size, ld_addr;
wire ld_start, ld_active, ld_end, ld_wr;
wire ft_spi_on, ft_vga_on, ft_reset;

kg_mcu2 #(.CAPS(16'h0210)) dut(
	.CLK(clk), .N_RESET(1'b1),
	.MCU_SCK(sck), .MCU_MOSI(mosi), .MCU_MISO(miso), .MCU_SS(ss), .MCU_INT(int_line),
	.MCU_SPI_FT_SS(1'b1), .MCU_SPI_SD2_SS(1'b1),
	.SW(sw), .SW_WR(sw_wr), .SW_INDEX(sw_index), .SW_VALUE(sw_value),
	.HW_ID(hw_id), .DVI_ONLY(dvi_only), .CORE_BUILD(core_build), .FW_BUILD(fw_build), .BUSY(busy),
	.BTNS(btns), .RELOAD_REQ(reload_req), .RELOAD_CORE(8'h2A),
	.KBD(kbd), .KBD_WR(kbd_wr), .PS2_CODE(ps2_code), .PS2_KIND(ps2_kind), .PS2_WR(ps2_wr),
	.MS_X(ms_x), .MS_Y(ms_y), .MS_Z(ms_z), .MS_B(ms_b), .MS_WR(ms_wr),
	.JOY_L(joy_l), .JOY_R(joy_r), .JOY_WR(joy_wr), .PS2_CMD(ps2_cmd), .PS2_CMD_WR(ps2_cmd_wr),
	.LD_KIND(ld_kind), .LD_SLOT(ld_slot), .LD_SIZE(ld_size), .LD_START(ld_start),
	.LD_ACTIVE(ld_active), .LD_END(ld_end), .LD_ADDR(ld_addr), .LD_DATA(ld_data), .LD_WR(ld_wr),
	.LD_READY(ld_ready),
	.FT_SPI_ON(ft_spi_on), .FT_VGA_ON(ft_vga_on), .FT_RESET(ft_reset),
	.FT_SCK(), .FT_MOSI(), .FT_MISO(1'b1), .FT_CS_N(),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

// counters of the strobes and what they carried
integer n_sw = 0, n_kbd = 0, n_ms = 0, n_joy = 0, n_ld_start = 0, n_ld_end = 0, n_ld_wr = 0;
integer n_ps2 = 0;
reg [15:0] ps2_log [0:15];
reg [7:0] mem [0:65535];
reg [31:0] ld_last = 0;
always @(posedge clk) begin
	if (sw_wr) n_sw = n_sw + 1;
	if (kbd_wr) n_kbd = n_kbd + 1;
	if (ms_wr) n_ms = n_ms + 1;
	if (joy_wr) n_joy = n_joy + 1;
	if (ld_start) n_ld_start = n_ld_start + 1;
	if (ld_end) n_ld_end = n_ld_end + 1;
	if (ld_wr) begin
		n_ld_wr = n_ld_wr + 1;
		mem[ld_addr[15:0]] = ld_data;
		ld_last = ld_addr;
	end
	if (ps2_wr) begin
		ps2_log[n_ps2[3:0]] = { 7'd0, ps2_kind, ps2_code };
		n_ps2 = n_ps2 + 1;
	end
end

// ---------------- the mcu ----------------

reg [7:0] rx [0:1023];
integer rxn;

task xbyte(input [7:0] b, output [7:0] r);
	integer i;
	begin
		for (i = 7; i >= 0; i = i - 1) begin
			mosi = b[i];
			#(SCK_HALF);
			sck = 1'b1;
			r[i] = miso;
			#(SCK_HALF);
			sck = 1'b0;
		end
		if (GAP > 0) #(GAP);
	end
endtask

reg [7:0] tx [0:1023];

// a packet of len bytes from tx[], the answers into rx[]
task packet(input integer len);
	integer i;
	reg [7:0] r;
	begin
		ss = 1'b0;
		#(SCK_HALF);
		for (i = 0; i < len; i = i + 1) begin
			xbyte(tx[i], r);
			rx[i] = r;
		end
		#(SCK_HALF);
		ss = 1'b1;
		rxn = len;
		#(1000); // the firmware takes more than a microsecond between packets
	end
endtask

task p3(input [7:0] a, input [7:0] b, input [7:0] c);
	begin tx[0] = a; tx[1] = b; tx[2] = c; end
endtask

integer i, base;

initial begin
	#(2000);

	// coldboot: INT is up after the configuration
	check("INT after configuration", int_line, 1);

	// SYS STATUS: T C Z then 8 bytes
	p3(8'h00, 8'h00, 8'h00);
	for (i = 3; i < 11; i = i + 1) tx[i] = 8'h00;
	packet(11);
	check("STATUS K", rx[3], "K");
	check("STATUS G", rx[4], "G");
	check("STATUS version", rx[5], 2);
	check("STATUS caps lo", rx[6], 8'h10);
	check("STATUS caps hi", rx[7], 8'h02);

	// SYS IRQ: ack 0, Z, pending
	p3(8'h00, 8'h01, 8'h00); tx[3] = 0; tx[4] = 0;
	packet(5);
	check("IRQ pending coldboot", rx[4], 8'h01);

	// SYS IRQ_SRC: Z, causes; clears coldboot
	p3(8'h00, 8'h02, 8'h00); tx[3] = 0;
	packet(4);
	check("IRQ_SRC coldboot", rx[3], 8'h01);
	#(200);
	check("INT after IRQ_SRC", int_line, 0);

	// SYS INIT 1, HW_SETUP board + dvi, build ids
	p3(8'h00, 8'h05, 8'h01); packet(3);
	check("BUSY", busy, 1);
	p3(8'h00, 8'h04, 8'h00); tx[3] = 8'h03; tx[4] = 8'h01; packet(5);
	check("HW_ID", hw_id, 3);
	check("DVI_ONLY", dvi_only, 1);
	p3(8'h00, 8'h04, 8'h10);
	for (i = 0; i < 16; i = i + 1) tx[3 + i] = (i < 8) ? "A" + i : "a" + i - 8;
	packet(19);
	check("CORE_BUILD", core_build, "ABCDEFGH");
	check("FW_BUILD", fw_build, "abcdefgh");

	// SYS SETVAL: three switches in one packet
	p3(8'h00, 8'h03, 8'h03); tx[3] = 8'h05; tx[4] = 8'h00; tx[5] = 8'h01; tx[6] = 8'h0F; tx[7] = 8'hAA;
	packet(8);
	check("SW 3", sw[3*8 +: 8], 8'h05);
	check("SW 0", sw[0 +: 8], 8'h01);
	check("SW 15", sw[15*8 +: 8], 8'hAA);
	check("SW_WR count", n_sw, 3);
	// the same value again is a write too
	p3(8'h00, 8'h03, 8'h03); tx[3] = 8'h05; packet(4);
	check("SW_WR repeat", n_sw, 4);

	// SYS SPI_CONTROL, BTN 0 and 4
	p3(8'h00, 8'h06, 8'h13); packet(3);
	check("FT_SPI_ON", ft_spi_on, 1);
	check("FT_VGA_ON", ft_vga_on, 1);
	check("FT_RESET", ft_reset, 1);
	p3(8'h00, 8'h07, 8'h00); tx[3] = 1; packet(4);
	p3(8'h00, 8'h07, 8'h04); tx[3] = 1; packet(4);
	check("BTNS", btns, 6'b010001);

	p3(8'h00, 8'h05, 8'h00); packet(3);
	check("BUSY off", busy, 0);

	// HID KBD
	p3(8'h01, 8'h01, 8'h02); tx[3] = 8'h00;
	for (i = 0; i < 6; i = i + 1) tx[4 + i] = 8'h04 + i;
	packet(10);
	check("KBD", kbd, { 8'h09, 8'h08, 8'h07, 8'h06, 8'h05, 8'h04, 8'h02 });
	check("KBD_WR count", n_kbd, 1);

	// HID MOUSE
	p3(8'h01, 8'h03, 8'hFE); tx[3] = 8'h03; tx[4] = 8'hFF; tx[5] = 8'h05; packet(6);
	check("MOUSE", { ms_x, ms_y, ms_z, ms_b }, 32'hFE03FF05);
	check("MS_WR count", n_ms, 1);

	// HID JOY: both ports in one packet
	p3(8'h01, 8'h04, 8'h00); tx[3] = 8'h23; tx[4] = 8'h01; tx[5] = 8'h01; tx[6] = 8'h45; tx[7] = 8'h10;
	packet(8);
	check("JOY_L", joy_l, 16'h0123);
	check("JOY_R", joy_r, 16'h1045);
	check("JOY_WR count", n_joy, 2);

	// HID PS2: E0 F0 75 (a set 2 release) and an XT byte
	p3(8'h01, 8'h02, 8'h00); tx[3] = 8'hE0; tx[4] = 8'h00; tx[5] = 8'hF0; tx[6] = 8'h00; tx[7] = 8'h75;
	tx[8] = 8'h01; tx[9] = 8'hC8;
	packet(10);
	check("PS2 count", n_ps2, 4);
	check("PS2 0", ps2_log[0], 16'h00E0);
	check("PS2 2", ps2_log[2], 16'h0075);
	check("PS2 3", ps2_log[3], 16'h01C8);

	// HID EVENT: two keyboard commands of the core
	@(posedge clk); ps2_cmd = 16'hED02; ps2_cmd_wr = 1'b1;
	@(posedge clk); ps2_cmd = 16'hF001;
	@(posedge clk); ps2_cmd_wr = 1'b0;
	#(200);
	check("INT on a core command", int_line, 1);
	p3(8'h00, 8'h01, 8'h00); tx[3] = 0; tx[4] = 0; packet(5);
	check("IRQ pending hid", rx[4], 8'h02);
	p3(8'h01, 8'h06, 8'h00);
	for (i = 3; i < 8; i = i + 1) tx[i] = 0;
	packet(8);
	check("EVENT count", rx[3], 2);
	check("EVENT 0", { rx[4], rx[5] }, 16'hED02);
	check("EVENT 1", { rx[6], rx[7] }, 16'hF001);
	#(200);
	check("INT after EVENT", int_line, 0);

	// SYS RELOAD
	@(posedge clk); reload_req = 1'b1;
	#(200);
	check("INT on reload", int_line, 1);
	p3(8'h00, 8'h02, 8'h00); tx[3] = 0; packet(4);
	check("IRQ_SRC reload", rx[3], 8'h02);
	p3(8'h00, 8'h08, 8'h00); tx[3] = 0; packet(4);
	check("RELOAD core", rx[3], 8'h2A);
	#(200);
	check("INT after RELOAD", int_line, 0);

	// LOAD: STATUS, START 0 (size 300), DATA 300 bytes at 1000, a DATA of another kind, END
	p3(8'h04, 8'h04, 8'h00); tx[3] = 0; packet(4);
	check("LOAD STATUS ready", rx[3], 1);
	ld_ready = 1'b0;
	packet(4);
	check("LOAD STATUS not ready", rx[3], 0);
	ld_ready = 1'b1;

	p3(8'h04, 8'h01, 8'h00); tx[3] = 8'h07;
	tx[4] = 8'h2C; tx[5] = 8'h01; for (i = 6; i < 12; i = i + 1) tx[i] = 0;
	tx[12] = "r"; tx[13] = "o"; tx[14] = "m";
	packet(15);
	check("LD_START", n_ld_start, 1);
	check("LD_ACTIVE", ld_active, 1);
	check("LD_SLOT", ld_slot, 7);
	check("LD_SIZE", ld_size, 300);
	check("LD_KIND", ld_kind, 0);

	p3(8'h04, 8'h02, 8'h00); tx[3] = 8'h00; tx[4] = 8'h10; tx[5] = 0; tx[6] = 0;
	for (i = 0; i < 300; i = i + 1) tx[7 + i] = i * 7 + 3;
	packet(307);
	check("LD_WR count", n_ld_wr, 300);
	base = 0;
	for (i = 0; i < 300; i = i + 1)
		if (mem[16'h1000 + i] !== ((i * 7 + 3) & 8'hFF)) base = base + 1;
	check("LD bytes", base, 0);
	check("LD last addr", ld_last, 32'h0000112B);

	p3(8'h04, 8'h02, 8'h01); tx[3] = 8'h00; tx[4] = 8'h20; tx[5] = 0; tx[6] = 0; tx[7] = 8'h55;
	packet(8);
	check("LD other kind dropped", n_ld_wr, 300);

	p3(8'h04, 8'h03, 8'h00); packet(3);
	check("LD_END", n_ld_end, 1);
	check("LD_ACTIVE off", ld_active, 0);

	// an unknown target and command are ignored, and the link is in step after them
	p3(8'h7F, 8'h33, 8'h44); for (i = 3; i < 20; i = i + 1) tx[i] = i; packet(20);
	p3(8'h00, 8'h00, 8'h00); for (i = 3; i < 11; i = i + 1) tx[i] = 0; packet(11);
	check("STATUS after junk", { rx[3], rx[4] }, "KG");

	$display("tb_kg_mcu2: %0d errors (sck half %0d ns, gap %0d ns)", errors, SCK_HALF, GAP);
	$finish;
end

endmodule
