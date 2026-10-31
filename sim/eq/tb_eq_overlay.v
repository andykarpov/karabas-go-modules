`timescale 1ns / 1ps

// overlay.vhd against kg_osd_overlay.v, ISim (overlay.vhd reads through latches, which ghdl
// --synth does not take): the font and the character memory loaded by commands, overlay and
// popup switched on and off during the frames, random video, three sync timings (counter steps
// of 1, 2 and 4 clocks); rgb_o compared after every clock.
// The flash counter of overlay.vhd has no initial value (0 on the FPGA), and ISim lets a VHDL
// signal fall back to its U driver when a force ends: the counter of both is held, 00 (flash
// off) until FLASH_T, then 20 (on); run_eq.sh forces the old one with the same values and time.
// V_OFFSET_IN: a third instance with the offset 72 on its input v_offset must give the output of
// the parameter V_OFFSET 72 every clock, a fourth with 64 must differ (the input is used).
// Ends with "tb_eq_overlay: N errors".

module tb_eq_overlay;

parameter FLASH_T = 60000000; // ns

`include "eq_check.vh"

reg clk = 1'b0;
always #10 clk = ~clk;

reg [23:0] rgb = 24'd0;
reg hs = 1'b0, vs = 1'b0;
reg [15:0] cmd = 16'd0;
wire [23:0] old_rgb, new_rgb;

overlay #(.H_OFFSET(120), .V_OFFSET(72)) old_dut(
	.CLK(clk), .RGB_I(rgb), .RGB_O(old_rgb), .HSYNC_I(hs), .VSYNC_I(vs), .OSD_COMMAND(cmd)
);
kg_osd_overlay #(.H_OFFSET(120), .V_OFFSET(72)) new_dut(
	.clk(clk), .rgb_i(rgb), .rgb_o(new_rgb), .hsync_i(hs), .vsync_i(vs), .osd_command(cmd)
);
wire [23:0] in72_rgb, in64_rgb;
kg_osd_overlay #(.H_OFFSET(120), .V_OFFSET(0), .V_OFFSET_IN(1)) in72_dut(
	.clk(clk), .rgb_i(rgb), .rgb_o(in72_rgb), .hsync_i(hs), .vsync_i(vs), .v_offset(11'd72), .osd_command(cmd)
);
kg_osd_overlay #(.H_OFFSET(120), .V_OFFSET(72), .V_OFFSET_IN(1)) in64_dut(
	.clk(clk), .rgb_i(rgb), .rgb_o(in64_rgb), .hsync_i(hs), .vsync_i(vs), .v_offset(11'd64), .osd_command(cmd)
);
integer in64_diffs = 0;
always @(negedge clk) begin
	eq_check("RGB_O v_offset 72", new_rgb, in72_rgb);
	if (in64_rgb !== new_rgb) in64_diffs = in64_diffs + 1;
end

// clocks with an OSD pixel (ink or paper, neither the video nor the dimmed video)
integer seed = 17, osd_clocks = 0;
wire [23:0] dim = { 3'b000, rgb[23:19], 3'b000, rgb[15:11], 3'b000, rgb[7:3] };

// popup or overlay switched: overlay.vhd keeps the cell addresses of the mode before in latches
// until its next read phase, kg_osd_overlay reads with the new mode at once. The next 3 cells
// (16 steps of up to 4 clocks) are not compared, their differences are counted.
integer settle = 0, transition_diffs = 0;
reg [1:0] mode_prev = 2'b00;
always @(negedge clk) begin
	if ({ new_dut.osd_popup, new_dut.osd_overlay } != mode_prev) settle = 3 * 16 * 4;
	else if (settle > 0) settle = settle - 1;
	mode_prev = { new_dut.osd_popup, new_dut.osd_overlay };
end

always @(negedge clk) begin
	if (settle > 0) begin
		if (old_rgb !== new_rgb) transition_diffs = transition_diffs + 1;
	end
	else
		eq_check("RGB_O", old_rgb, new_rgb);
	if (new_rgb !== rgb && new_rgb !== dim) osd_clocks = osd_clocks + 1;
	rgb <= $random(seed);
end

// a write of the cell being read (or the font line) in the same clock: a collision of the block
// RAM ports, undefined on the FPGA
integer collisions = 0;
always @(posedge clk) begin
	if (new_dut.vram_wr && new_dut.addr_write == new_dut.addr_read) begin
		collisions = collisions + 1;
	end
	if (new_dut.font_we && new_dut.font_addr == new_dut.rom_addr) begin
		collisions = collisions + 1;
	end
end

// ---------------- video timing ----------------

integer line_len = 448, lines = 312, frames_left = 0;
integer hx = 0, vy = 0;
// all inputs change at the falling clock: the VHDL and the Verilog processes of the rising edge
// would see a change made at that edge in a different order
always @(negedge clk) begin
	hx = hx + 1;
	if (hx == line_len) begin
		hx = 0;
		vy = vy + 1;
		if (vy == lines) begin
			vy = 0;
			if (frames_left > 0) frames_left = frames_left - 1;
		end
	end
	hs <= hx < line_len / 10;
	vs <= vy < 3;
end

// ---------------- commands ----------------

task command(input [7:0] c, input [7:0] v);
	begin
		// a command is taken when the word changes: a neutral word in between
		@(negedge clk);
		cmd = 16'hFF00;
		repeat (3) @(negedge clk);
		cmd = { c, v };
		repeat (2) @(negedge clk);
	end
endtask

integer i, x, y, m;
reg [31:0] r;

// random cells now and then while the frames run
task random_cells(input integer n);
	integer k;
	begin
		for (k = 0; k < n; k = k + 1) begin
			r = $random(seed);
			command(8'h10, r[4:0]);
			command(8'h11, r[9:5] % 26);
			command(8'h12, r[17:10]);
			command(8'h13, r[31:24]);
			repeat (r[23:18] * 50) @(posedge clk);
		end
	end
endtask

task frames(input integer n);
	begin
		frames_left = n;
		while (frames_left > 0) begin
			r = $random(seed);
			case (r[2:0])
				3'd0: command(8'h02, r[3]);  // popup
				3'd1: command(8'h01, r[3]);  // overlay
				default: random_cells(4);
			endcase
		end
	end
endtask

initial begin
	force new_dut.flash_cnt = 8'h00;
	force in72_dut.flash_cnt = 8'h00;
	force in64_dut.flash_cnt = 8'h00;
	#(FLASH_T);
	force new_dut.flash_cnt = 8'h20;
	force in72_dut.flash_cnt = 8'h20;
	force in64_dut.flash_cnt = 8'h20;
end

initial begin
	repeat (10) @(posedge clk);
	// the font: 2048 random bytes
	command(8'h20, 8'h01);
	for (i = 0; i < 2048; i = i + 1) command(8'h21, $random(seed));
	// every cell, a random character and attribute, some flashing
	for (y = 0; y < 32; y = y + 1)
		for (x = 0; x < 32; x = x + 1) begin
			r = $random(seed);
			command(8'h10, x);
			command(8'h11, y);
			command(8'h12, r[7:0]);
			command(8'h13, (r[11:8] == 0) ? { r[15:12], 4'b0001 } : r[23:16]);
		end
	for (m = 0; m < 3; m = m + 1) begin
		case (m)
			0: begin line_len = 448;  lines = 312;  end // steps of 1 clock
			1: begin line_len = 864;  lines = 625;  end // of 2
			2: begin line_len = 1100; lines = 840;  end // of 4
		endcase
		command(8'h01, 8'h01);
		command(8'h02, 8'h00);
		frames(1);              // the counters learn the new timing
		frames(m == 0 ? 4 : 2);
		command(8'h02, 8'h01);  // popup
		command(8'h01, 8'h00);
		frames(2);
	end
	$display("tb_eq_overlay: %0d clocks with osd, %0d checks, %0d collisions, %0d differences after a mode switch",
		osd_clocks, checks, collisions, transition_diffs);
	$display("tb_eq_overlay: %0d clocks differ with v_offset 64", in64_diffs);
	if (in64_diffs == 0) begin
		$display("ERROR: v_offset 64 gives the output of 72");
		errors = errors + 1;
	end
	$display("tb_eq_overlay: %0d errors", errors);
	$finish;
end

endmodule
