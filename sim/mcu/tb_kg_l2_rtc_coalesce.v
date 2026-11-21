`timescale 1ns / 1ps

/*
 tb_kg_l2_rtc_coalesce.v

 kg_l2_rtc with COALESCE (kg_mcu2 RTC_COALESCE 1, RTC_SEND_LIMIT 128) and a model of the mcu
 that does what the firmware does (link_api.c v2_rtc_event: GET of 17 bytes, at most 8 pairs
 applied in order to its copy of the registers):
 - a burst of 150 writes (the SETUP of Sprinter: per register a write of the complement of the
   test cell 7F, its restore, the value) with no GET meanwhile: the mcu copy gets every register
   with its last value, at most 8 a GET, a register once in a GET, C and D never;
 - a SET packet of the mcu over registers the core wrote and the mcu has not read: the core
   keeps its values (the others take the SET), the mcu gets them by GET, a SET after that is
   written again;
 - random writes (registers 0..127, also the same register in consecutive clocks) while the mcu
   reads GET and sends SET packets of 0..9 (its copy) at random times: at the end the mcu copy =
   the last write of the core of every register, the RAM the core reads = that too.
 - a write of a register in the clock the scanner takes it (the pointer peeked, offsets -3..+3):
   the mcu ends with the second value.
 Prints "tb_kg_l2_rtc_coalesce: 0 errors".
*/

module tb_kg_l2_rtc_coalesce;

reg clk = 1'b0;      // 28 MHz
always #17.86 clk = ~clk;

integer errors = 0;
task check(input [255:0] what, input [63:0] got, input [63:0] want);
	if (got !== want) begin
		$display("ERROR %0s: got %h, want %h", what, got, want);
		errors = errors + 1;
	end
endtask

reg sck = 1'b0, mosi = 1'b0, ss = 1'b1;
wire miso, int_line;

reg [7:0] rtc_a = 8'd0, rtc_di = 8'd0;
reg rtc_cs = 1'b0, rtc_wr_n = 1'b1;
wire [7:0] rtc_do;

kg_mcu2 #(.ENABLE_OSD(0), .ENABLE_RTC(1), .RTC_SEND_LIMIT(128), .RTC_COALESCE(1)) dut(
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
	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'd0), .PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0),
	.PORT_IN_FULL(), .PORT_CFG(128'd0), .PORT_STAT(), .PORT_STAT_WR(),
	.RTC_A(rtc_a), .RTC_DI(rtc_di), .RTC_DO(rtc_do), .RTC_CS(rtc_cs), .RTC_WR_N(rtc_wr_n),
	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),
	.FT_SPI_ON(), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(), .FT_MISO(1'b1), .FT_CS_N(),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

// ---------------- the mcu: SPI packets, one at a time (sem)

reg [7:0] tx [0:1023];
reg [7:0] rx [0:1023];
reg mcu_lock = 1'b0;

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
		#16; ss = 1'b1; #1000;
	end
endtask

// the mcu copy of the registers (rtc_set_data: the firmware keeps every register the core wrote)
reg [7:0] mcu_reg [0:127];
reg [127:0] mcu_got = 128'd0;
integer gets = 0, pairs = 0;

// GET as v2_rtc_event: 17 bytes, ev[0] pairs, at most 8 applied
task mcu_get;
	integer i, k;
	reg [127:0] seen;
	begin
		tx[0] = 8'h06; tx[1] = 8'h02;
		for (i = 2; i < 20; i = i + 1) tx[i] = 8'h00;
		packet(20);
		gets = gets + 1;
		if (rx[3] > 8) begin
			$display("ERROR GET count %0d > 8", rx[3]);
			errors = errors + 1;
		end
		seen = 128'd0;
		for (k = 0; k < rx[3] && k < 8; k = k + 1) begin
			if (rx[4 + 2 * k] > 8'd127 || rx[4 + 2 * k] == 8'h0C || rx[4 + 2 * k] == 8'h0D) begin
				$display("ERROR GET register %h", rx[4 + 2 * k]);
				errors = errors + 1;
			end
			else begin
				if (seen[rx[4 + 2 * k]]) begin
					$display("ERROR register %h twice in a GET", rx[4 + 2 * k]);
					errors = errors + 1;
				end
				seen[rx[4 + 2 * k]] = 1'b1;
				mcu_reg[rx[4 + 2 * k]] = rx[5 + 2 * k];
				mcu_got[rx[4 + 2 * k]] = 1'b1;
			end
			pairs = pairs + 1;
		end
	end
endtask

// SET: first register f, n values from sv[]
reg [7:0] sv [0:255];
task mcu_set(input [7:0] f, input integer cnt);
	integer i;
	begin
		tx[0] = 8'h06; tx[1] = 8'h01; tx[2] = f;
		for (i = 0; i < cnt; i = i + 1) tx[3 + i] = sv[i];
		packet(3 + cnt);
	end
endtask

// the irq bits of the link (00 01): bit 6 RTC
task irq_bits(output [7:0] bits);
	begin
		tx[0] = 8'h00; tx[1] = 8'h01; tx[2] = 8'h00; tx[3] = 8'h00; tx[4] = 8'h00;
		packet(5);
		bits = rx[4];
	end
endtask

// drain: GET while the RTC irq is up (the main loop of the firmware)
task mcu_drain;
	integer guard;
	reg [7:0] bits;
	begin
		guard = 0;
		#5000; // the scanner refills the fifo within 128 clocks (4.6 us)
		irq_bits(bits);
		while (bits[6] && guard < 200) begin
			mcu_get;
			#5000;
			irq_bits(bits);
			guard = guard + 1;
		end
		if (bits[6]) begin
			$display("ERROR the irq does not end");
			errors = errors + 1;
		end
	end
endtask

// ---------------- the core

reg [7:0] last [0:127];    // the last write of the core of each register
reg [127:0] written = 128'd0;

task core_wr(input [7:0] a, input [7:0] v);
	begin
		@(posedge clk); rtc_a <= a; rtc_di <= v; rtc_cs <= 1'b1; rtc_wr_n <= 1'b0;
		@(posedge clk); rtc_cs <= 1'b0; rtc_wr_n <= 1'b1;
		if (a != 8'h0C && a != 8'h0D) begin
			last[a] = v;
			written[a] = 1'b1;
		end
	end
endtask

task core_rd(input [7:0] a, output [7:0] v);
	begin
		@(posedge clk); rtc_a <= a;
		@(posedge clk); @(posedge clk); v = rtc_do;
	end
endtask

task compare_all(input [255:0] what);
	integer i;
	reg [7:0] v;
	begin
		for (i = 0; i < 128; i = i + 1)
			if (written[i]) begin
				if (!mcu_got[i] || mcu_reg[i] !== last[i]) begin
					$display("ERROR %0s: mcu register %h = %h (got %b), the core wrote %h", what, i[7:0], mcu_reg[i],
						mcu_got[i], last[i]);
					errors = errors + 1;
				end
				core_rd(i[7:0], v);
				if (v !== last[i]) begin
					$display("ERROR %0s: core register %h = %h, wrote %h", what, i[7:0], v, last[i]);
					errors = errors + 1;
				end
			end
			else if (mcu_got[i]) begin
				$display("ERROR %0s: register %h sent, never written", what, i[7:0]);
				errors = errors + 1;
			end
	end
endtask

task reset_books;
	integer i;
	begin
		for (i = 0; i < 128; i = i + 1) mcu_reg[i] = 8'hEE;
		mcu_got = 128'd0;
		written = 128'd0;
	end
endtask

integer i, k, seed, n_wr;
reg [7:0] v, a, tcell, ib;
reg stop_mcu;
initial begin
	seed = 7;
	#2000;
	tx[0] = 8'h00; tx[1] = 8'h05; tx[2] = 8'h00; packet(3); // INIT done (busy off)

	// ---- 1. the SETUP burst: 50 registers 0E..3F, each with the test of 7F before it
	reset_books;
	tcell = 8'h00;
	for (i = 8'h0E; i <= 8'h3F; i = i + 1) begin
		core_wr(8'h7F, ~tcell);
		core_wr(8'h7F, tcell);
		core_wr(i[7:0], i[7:0] ^ 8'h5A);
		repeat (20) @(posedge clk);   // ~20 us a BIOS call at 21 MHz; here faster
	end
	core_wr(8'h0C, 8'h11);           // C and D: never sent
	core_wr(8'h0D, 8'h22);
	mcu_drain;
	compare_all("burst");
	$display("burst: %0d GETs, %0d pairs for 150 writes", gets, pairs);

	// ---- 2. SET over registers the core wrote and the mcu has not read
	reset_books;
	core_wr(8'h00, 8'h45);
	core_wr(8'h02, 8'h30);
	for (i = 0; i < 10; i = i + 1) sv[i] = 8'h90 + i;
	#3000;
	mcu_set(8'h00, 10);
	core_rd(8'h00, v); check("held reg 0", v, 8'h45);
	core_rd(8'h02, v); check("held reg 2", v, 8'h30);
	core_rd(8'h01, v); check("SET reg 1", v, 8'h91);
	core_rd(8'h09, v); check("SET reg 9", v, 8'h99);
	mcu_drain;
	compare_all("set race");
	mcu_set(8'h00, 10);
	core_rd(8'h00, v); check("reg 0 after GET", v, 8'h90);
	core_rd(8'h02, v); check("reg 2 after GET", v, 8'h92);

	// ---- 3. random writes while the mcu reads and sets at random
	reset_books;
	stop_mcu = 1'b0;
	n_wr = 0;
	fork
		begin
			for (k = 0; k < 3000; k = k + 1) begin
				a = $random(seed) & 8'h7F;
				if (a == 8'h0C || a == 8'h0D) a = 8'h40;
				if (($random(seed) & 3) == 0) begin
					// the same register in consecutive clocks (several values in a row)
					core_wr(a, $random(seed));
					core_wr(a, $random(seed));
				end
				else
					core_wr(a, $random(seed));
				n_wr = n_wr + 1;
				repeat ($random(seed) & 31) @(posedge clk);
			end
			stop_mcu = 1'b1;
		end
		begin
			while (!stop_mcu) begin
				irq_bits(ib);
				if (ib[6] && ($random(seed) & 1)) mcu_get;
				else if (($random(seed) & 7) == 0) begin
					// the time packet: the mcu sends its copy (what it took from the core), else its clock
					for (i = 0; i < 10; i = i + 1) sv[i] = mcu_got[i] ? mcu_reg[i] : $random(seed);
					mcu_set(8'h00, 10);
				end
				#(($random(seed) & 8'hFF) * 40);
			end
		end
	join
	mcu_drain;
	compare_all("random");
	$display("random: %0d write calls, %0d GETs, %0d pairs", n_wr, gets, pairs);

	// ---- 4. a write in the clock the scanner takes the same register (the scanner pointer is
	// peeked to hit it): a register with a pending value written again around the take, offsets
	// -3..+3 clocks; the mcu must end with the second value
	reset_books;
	for (k = 0; k < 7; k = k + 1) begin
		a = 8'h20 + k * 8;
		core_wr(a, 8'h11);
		@(negedge clk);
		while (dut.kg_mcu2_rtc_on.u_rtc.rtc_coalesce.ptr !== a[6:0] - 7'd3 + k[6:0] - 7'd1) @(negedge clk);
		core_wr(a, 8'h22 + k);
		mcu_drain;
	end
	compare_all("same clock");

	$display("tb_kg_l2_rtc_coalesce: %0d errors", errors);
	$finish;
end

endmodule
