`timescale 1ns / 1ps

/*
 tb_kg_l2_rpc.v

 The RPC mailbox of link v2: kg_mcu2 with target 08 (kg_l2_rpc), a model of the mcu and the bus of
 the core's CPU. Checked: no interrupt before HELLO, HELLO (version, max payload, services, caps
 bit 10), the call as SYS IRQ byte 2, REQ (header, payload, sum; again; the interrupt ends after the
 sum), RESP refused (bad sum, another id, no call) and taken (status, length, payload of 300 and 512
 bytes), EVENT taken / refused while the slot is full (its payload kept) / free again.
 Prints "tb_kg_l2_rpc: 0 errors".
*/

module tb_kg_l2_rpc;

reg clk = 1'b0;      // 75 MHz, as the boot menu
always #6.67 clk = ~clk;

integer errors = 0;
task check(input [255:0] what, input [63:0] got, input [63:0] want);
	if (got !== want) begin
		$display("ERROR %0s: got %h, want %h", what, got, want);
		errors = errors + 1;
	end
endtask

reg sck = 1'b0, mosi = 1'b0, ss = 1'b1;
wire miso, int_line;
reg [10:0] rpc_a = 11'd0;
reg rpc_we = 1'b0;
reg [7:0] rpc_wd = 8'd0;
wire [7:0] rpc_rd;

kg_mcu2 #(.ENABLE_OSD(0), .ENABLE_RPC(1), .RPC_SERVICES(16'h000F)) dut(
	.CLK(clk), .N_RESET(1'b1),
	.MCU_SCK(sck), .MCU_MOSI(mosi), .MCU_MISO(miso), .MCU_SS(ss), .MCU_INT(int_line),
	.MCU_SPI_FT_SS(1'b1), .MCU_SPI_SD2_SS(1'b1),
	.SW(), .SW_WR(), .SW_INDEX(), .SW_VALUE(), .HW_ID(), .DVI_ONLY(), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(), .BTNS(), .RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),
	.KBD(), .KBD_WR(), .PS2_CODE(), .PS2_KIND(), .PS2_WR(), .MS_X(), .MS_Y(), .MS_Z(), .MS_B(),
	.MS_WR(), .JOY_L(), .JOY_R(), .JOY_WR(), .PS2_CMD(16'd0), .PS2_CMD_WR(1'b0),
	.LD_KIND(), .LD_SLOT(), .LD_SIZE(), .LD_START(), .LD_ACTIVE(), .LD_END(), .LD_ADDR(),
	.LD_DATA(), .LD_WR(), .LD_READY(1'b1),
	.OSD_WR(), .OSD_WADDR(), .OSD_WDATA(), .OSD_EN(), .OSD_FG(), .OSD_BG(), .OSD_ALPHA(),
	.OSD_PX(), .OSD_PY(), .OSD_PW(), .OSD_PH(), .OSD_PLACE(), .OSD_ZOOM(),
	.SDC_IMG_MOUNTED(), .SDC_IMG_SIZE(), .SDC_RD(8'd0), .SDC_WR(8'd0), .SDC_SECTOR(32'd0),
	.SDC_BUSY(), .SDC_DONE(), .SDC_ERROR(), .SDC_SLOT(), .SDC_BYTE_IN_STROBE(), .SDC_BYTE_ADDR(),
	.SDC_BYTE_IN_DATA(), .SDC_BYTE_OUT_DATA(8'd0), .IMG_WP(), .IMG_PHYS_WR(), .IMG_PHYS(),
	.IMG_FLUSH(), .FDD_CHNG_WR(), .FDD_CHNG(), .FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0), .IMG_ACTIVE(),
	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'b1111),
	.PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0), .PORT_IN_FULL(), .PORT_CFG(128'd0),
	.PORT_STAT(), .PORT_STAT_WR(),
	.RPC_A(rpc_a), .RPC_WE(rpc_we), .RPC_WD(rpc_wd), .RPC_RD(rpc_rd),
	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_DO(), .RTC_CS(1'b0), .RTC_WR_N(1'b1),
	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),
	.FT_SPI_ON(), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(), .FT_MISO(1'b1), .FT_CS_N(),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

// ---------------- the CPU of the core ----------------
task cpu_wr(input [10:0] a, input [7:0] v);
	begin
		@(posedge clk); #1; rpc_a = a; rpc_wd = v; rpc_we = 1'b1;
		@(posedge clk); #1; rpc_we = 1'b0;
	end
endtask
task cpu_rd(input [10:0] a, output [7:0] v);
	begin
		@(posedge clk); #1; rpc_a = a;
		@(posedge clk); @(posedge clk); #1; v = rpc_rd;
	end
endtask

// ---------------- the mcu ----------------
reg [7:0] tx [0:1100];
reg [7:0] rx [0:1100];

task xbyte(input [7:0] b, output [7:0] r);
	integer i;
	begin
		for (i = 7; i >= 0; i = i - 1) begin
			mosi = b[i];
			#16; sck = 1'b1; r[i] = miso;
			#16; sck = 1'b0;
		end
	end
endtask

task packet(input integer len);
	integer i;
	reg [7:0] r;
	begin
		ss = 1'b0; #16;
		for (i = 0; i < len; i = i + 1) begin
			xbyte(tx[i], r);
			rx[i] = r;
		end
		#16; ss = 1'b1; #500;
	end
endtask

task clear_tx;
	integer i;
	for (i = 0; i < 1100; i = i + 1) tx[i] = 8'h00;
endtask

// RESP / EVENT: T C h0 h1 len lo hi payload sum lo hi Z ack; the payload byte k = base + 3 k
reg [7:0] ack;
task send(input [7:0] c, input [7:0] h0, input [7:0] h1, input integer len, input [7:0] base, input bad_sum);
	integer i;
	reg [15:0] s;
	begin
		clear_tx;
		tx[0] = 8'h08; tx[1] = c; tx[2] = h0; tx[3] = h1; tx[4] = len[7:0]; tx[5] = len[15:8];
		s = h0 + h1 + len[7:0] + len[15:8];
		for (i = 0; i < len; i = i + 1) begin
			tx[6 + i] = base + 3 * i;
			s = s + tx[6 + i];
		end
		if (bad_sum) s = s + 1;
		tx[6 + len] = s[7:0]; tx[7 + len] = s[15:8];
		packet(10 + len);
		ack = rx[9 + len];
	end
endtask

// REQ: T C Z id svc fn len lo hi payload sum lo hi
reg [7:0] q_id, q_svc, q_fn;
integer q_len;
reg [15:0] q_sum, q_calc;
task req(input integer len);
	integer i;
	begin
		clear_tx;
		tx[0] = 8'h08; tx[1] = 8'h03;
		packet(10 + len);
		q_id = rx[3]; q_svc = rx[4]; q_fn = rx[5]; q_len = { rx[7], rx[6] };
		q_calc = rx[3] + rx[4] + rx[5] + rx[6] + rx[7];
		for (i = 0; i < len; i = i + 1) q_calc = q_calc + rx[8 + i];
		q_sum = { rx[9 + len], rx[8 + len] };
	end
endtask

task status(output [7:0] flags);
	begin
		clear_tx; tx[0] = 8'h08; tx[1] = 8'h02; packet(6); flags = rx[3];
	end
endtask

// the CPU makes a call: the payload byte k = base + 7 k
task call(input [7:0] id, input [7:0] svc, input [7:0] fn, input integer len, input [7:0] base);
	integer i;
	begin
		for (i = 0; i < len; i = i + 1) cpu_wr(i, base + 7 * i);
		cpu_wr(11'h600, id); cpu_wr(11'h601, svc); cpu_wr(11'h602, fn);
		cpu_wr(11'h603, len[7:0]); cpu_wr(11'h604, len[15:8]);
		cpu_wr(11'h605, 8'h01);
	end
endtask

integer i, bad;
reg [7:0] v, flags;
initial begin
	#2000;
	// the coldboot cause of SYS (IRQ bit 0) cleared first: INT is then the RPC only
	clear_tx; tx[0] = 8'h00; tx[1] = 8'h02; packet(4);
	// caps bit 10
	clear_tx; tx[0] = 8'h00; tx[1] = 8'h00; packet(12);
	check("STATUS caps hi bit 10", rx[7] & 8'h04, 8'h04);

	// a call before HELLO: no interrupt
	call(8'h21, 8'h02, 8'h01, 5, 8'h10);
	#1000;
	check("no INT before HELLO", int_line, 1'b0);
	status(flags);
	check("STATUS before HELLO", flags, 8'h03);  // waiting, slot free, not enabled

	// HELLO
	clear_tx; tx[0] = 8'h08; tx[1] = 8'h01; tx[2] = 8'h01; packet(9);
	check("HELLO version", rx[4], 8'd1);
	check("HELLO max", { rx[6], rx[5] }, 16'd512);
	check("HELLO services", { rx[8], rx[7] }, 16'h000F);
	#1000;
	check("INT after HELLO", int_line, 1'b1);
	cpu_rd(11'h618, v); check("fw version", v, 8'd1);
	cpu_rd(11'h608, v); check("cpu flags busy, enabled", v, 8'h09);

	// SYS IRQ: the second byte
	clear_tx; tx[0] = 8'h00; tx[1] = 8'h01; packet(6);
	check("IRQ byte 1", rx[4], 8'h00);
	check("IRQ byte 2", rx[5], 8'h01);

	// REQ
	req(5);
	check("REQ id", q_id, 8'h21); check("REQ svc", q_svc, 8'h02); check("REQ fn", q_fn, 8'h01);
	check("REQ len", q_len, 5);
	bad = 0;
	for (i = 0; i < 5; i = i + 1) if (rx[8 + i] !== ((8'h10 + 7 * i) & 8'hFF)) bad = bad + 1;
	check("REQ payload", bad, 0);
	check("REQ sum", q_sum, q_calc);
	#1000;
	check("INT ends after REQ", int_line, 1'b0);
	status(flags);
	check("STATUS waiting after REQ", flags, 8'h07);
	req(5);
	check("REQ again sum", q_sum, q_calc);
	check("REQ again payload 4", rx[12], 8'h10 + 28);

	// RESP refused: bad sum, another id
	send(8'h04, 8'h21, 8'h00, 3, 8'h40, 1'b1);
	check("RESP bad sum refused", ack, 8'h01);
	send(8'h04, 8'h22, 8'h00, 3, 8'h40, 1'b0);
	check("RESP other id refused", ack, 8'h01);
	cpu_rd(11'h608, v); check("no response yet", v & 8'h03, 8'h01);
	// RESP taken
	send(8'h04, 8'h21, 8'h05, 300, 8'h40, 1'b0);
	check("RESP taken", ack, 8'h00);
	cpu_rd(11'h608, v); check("response in", v & 8'h03, 8'h02);
	cpu_rd(11'h609, v); check("resp status", v, 8'h05);
	cpu_rd(11'h60A, v); check("resp len lo", v, 8'd44);
	cpu_rd(11'h60B, v); check("resp len hi", v, 8'd1);
	cpu_rd(11'h60C, v); check("resp id", v, 8'h21);
	bad = 0;
	for (i = 0; i < 300; i = i + 1) begin
		cpu_rd(11'h200 + i, v);
		if (v !== ((8'h40 + 3 * i) & 8'hFF)) bad = bad + 1;
	end
	check("RESP payload", bad, 0);
	// RESP with no call
	send(8'h04, 8'h21, 8'h00, 2, 8'h00, 1'b0);
	check("RESP without a call refused", ack, 8'h01);
	cpu_rd(11'h200, v); check("RESP payload kept", v, 8'h40);

	// the largest call and response: 512 bytes
	call(8'h22, 8'h04, 8'h02, 512, 8'h01);
	#1000;
	check("INT for call 2", int_line, 1'b1);
	req(512);
	check("REQ 512 len", q_len, 512);
	check("REQ 512 sum", q_sum, q_calc);
	check("REQ 512 last", rx[8 + 511], (8'h01 + 7 * 511) & 8'hFF);
	send(8'h04, 8'h22, 8'h00, 512, 8'h07, 1'b0);
	check("RESP 512 taken", ack, 8'h00);
	cpu_rd(11'h200 + 511, v); check("RESP 512 last", v, (8'h07 + 3 * 511) & 8'hFF);
	send(8'h04, 8'h22, 8'h00, 513, 8'h07, 1'b0);
	check("RESP 513 refused", ack, 8'h01);

	// EVENT
	send(8'h05, 8'h03, 8'h01, 4, 8'h90, 1'b0);
	check("EVENT taken", ack, 8'h00);
	cpu_rd(11'h608, v); check("event in", v & 8'h04, 8'h04);
	cpu_rd(11'h610, v); check("evt svc", v, 8'h03);
	cpu_rd(11'h611, v); check("evt code", v, 8'h01);
	cpu_rd(11'h612, v); check("evt len", v, 8'd4);
	cpu_rd(11'h403, v); check("evt payload 3", v, 8'h99);
	status(flags);
	check("STATUS slot full", flags & 8'h02, 8'h00);
	send(8'h05, 8'h03, 8'h02, 4, 8'h20, 1'b0);
	check("EVENT while full refused", ack, 8'h01);
	cpu_rd(11'h403, v); check("evt payload kept", v, 8'h99);
	cpu_wr(11'h614, 8'h00);
	status(flags);
	check("STATUS slot free", flags & 8'h02, 8'h02);
	send(8'h05, 8'h03, 8'h02, 4, 8'h20, 1'b1);
	check("EVENT bad sum refused", ack, 8'h01);
	cpu_rd(11'h608, v); check("no event after bad sum", v & 8'h04, 8'h00);
	send(8'h05, 8'h03, 8'h02, 0, 8'h20, 1'b0);
	check("EVENT empty taken", ack, 8'h00);
	cpu_rd(11'h611, v); check("evt code 2", v, 8'h02);

	$display("tb_kg_l2_rpc: %0d errors", errors);
	$finish;
end

endmodule
