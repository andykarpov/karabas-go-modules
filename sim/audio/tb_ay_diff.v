`timescale 1ns / 1ps
// kg_ym2149 (ay38910_silicon.v) against ay_model.v, the transistor-level model of the AY-3-8910 by
// lvd2 / deathsoft (github.com/lvd2/ay-3-8910_reverse_engineered, GPL v3; run_audio_sim.sh fetches
// it and turns its trireg nets into keepers, lvd2_keeper.py).
//
// kg_ym2149 is driven as turbosound.v does: CE = clk / 8, SEL = 1 (the AY clock is clk / 16), idle =
// read (BDIR 0, BC 1), an address or a data write one clock long, DI held after it. The model gets
// the same writes on its asynchronous bus (inactive between them) and its clock rises at the clock
// edge where the clk / 8 divider of ay38910_silicon counts. Writes come at random phases and in
// sweeps over the 128 phases of a clk / 8 period (16 clocks per AY clock x 8).
// Checked at every AY clock (not in a clock with a write pulse, where the model already has the new
// value and the registers of ay38910_silicon get it at the end): the three channel levels, F_ENV
// (the clock of the envelope state machine), CHANNEL_A..C = the DDp table of the model's levels;
// the YM mode (a second kg_ym2149, MODE 0, same bus) has no reference: its 5-bit levels must be
// the AY levels with one bit more (the envelope steps on both edges of F_ENV, fixed N = 2N+1).
// Register reads (all 16, R7 ports as inputs and outputs) against the model.
module tb_ay_diff;

reg clk = 1'b0;
always #20 clk = ~clk;

// CE of turbosound: 3.5 MHz of 28 MHz
reg [2:0] div = 3'd0;
reg ce = 1'b0;
always @(posedge clk) begin
	div <= div + 3'd1;
	ce  <= (div == 3'd7);
end

integer errors = 0;
reg        rst = 1'b1;
reg        bdir = 1'b0, bc = 1'b1;     // kg_ym2149
reg  [7:0] di = 8'd0;
reg        m_bdir = 1'b0, m_bc1 = 1'b0; // the model (bc2 = 1)
reg        da_en = 1'b1;

wire [7:0] do_ay, do_ym;
wire [7:0] cha, chb, chc;
wire [7:0] ioa_ay;

kg_ym2149 dut (
	.CLK(clk), .CE(ce), .RESET(rst), .BDIR(bdir), .BC(bc), .DI(di), .DO(do_ay),
	.CHANNEL_A(cha), .CHANNEL_B(chb), .CHANNEL_C(chc),
	.SEL(1'b1), .MODE(1'b1), .ACTIVE(),
	.IOA_in(8'hFF), .IOA_out(ioa_ay), .IOB_in(8'hFF), .IOB_out()
);

kg_ym2149 dut_ym (
	.CLK(clk), .CE(ce), .RESET(rst), .BDIR(bdir), .BC(bc), .DI(di), .DO(do_ym),
	.CHANNEL_A(), .CHANNEL_B(), .CHANNEL_C(),
	.SEL(1'b1), .MODE(1'b0), .ACTIVE(),
	.IOA_in(8'hFF), .IOA_out(), .IOB_in(8'hFF), .IOB_out()
);

// the model's clock: up at the edge where ay38910_silicon counts (CE with the SEL divider of
// kg_ym2149 at 1), 8 clocks high, 8 low; it runs in the reset too (the model needs its clock there),
// the reset ends when t = 0 (sel_div of kg_ym2149 is 0 in the reset), so ce_p = dut.ay_ce_p after it
reg  t = 1'b0;
always @(posedge clk) if (ce) t <= ~t;
wire ce_p = ce & t;
reg  ay_clk = 1'b0;
reg  [3:0] hc = 4'd0;
always @(posedge clk) begin
	if (!rst && ce_p !== dut.ay_ce_p) begin
		$display("ERROR %0t: the clock of the model is not the one of kg_ym2149", $time);
		errors = errors + 1;
	end
	if (ce_p) begin
		ay_clk <= 1'b1;
		hc     <= 4'd0;
	end else begin
		hc <= hc + 4'd1;
		if (hc == 4'd7) ay_clk <= 1'b0;
	end
end

wire [7:0] da_bus = da_en ? di : 8'hzz;
tri1 [7:0] ioa_bus;
tri1 [7:0] iob_bus;
wire [3:0] ref_a, ref_b, ref_c;

ay_model u_ref (
	.clk(ay_clk), ._rst(~rst),
	.da(da_bus), .bdir(m_bdir), .bc2(1'b1), .bc1(m_bc1), .a8(1'b1), ._a9(1'b0),
	.ioa(ioa_bus), .iob(iob_bus), .test1(), .test2(1'b0),
	.ch_a(ref_a), .ch_b(ref_b), .ch_c(ref_c)
);

function [7:0] ddp;
	input [3:0] l;
	begin
		case (l)
			4'd0: ddp = 8'd0;    4'd1: ddp = 8'd3;    4'd2: ddp = 8'd4;    4'd3: ddp = 8'd5;
			4'd4: ddp = 8'd8;    4'd5: ddp = 8'd12;   4'd6: ddp = 8'd16;   4'd7: ddp = 8'd27;
			4'd8: ddp = 8'd33;   4'd9: ddp = 8'd52;   4'd10: ddp = 8'd75;  4'd11: ddp = 8'd95;
			4'd12: ddp = 8'd126; 4'd13: ddp = 8'd162; 4'd14: ddp = 8'd205; default: ddp = 8'd255;
		endcase
	end
endfunction

integer checks = 0;
integer env_checks = 0;
reg     check_en = 1'b0;
reg     quiet = 1'b0;   // no write in this clock or the one before (CHANNEL_* are one clock late)
reg     bdir_d = 1'b0;

task automatic err;
	input [8*48-1:0] what;
	begin
		if (errors < 20)
			$display("ERROR %0t: %0s: ref A=%0d B=%0d C=%0d f_env=%b | ay A=%0d B=%0d C=%0d f_env=%b CH=%0d,%0d,%0d | ym %0d,%0d,%0d",
				$time, what, ref_a, ref_b, ref_c, u_ref.f_env,
				dut.u_ay.ch_a_raw, dut.u_ay.ch_b_raw, dut.u_ay.ch_c_raw, dut.u_ay.f_env, cha, chb, chc,
				dut_ym.u_ay.ch_a_5b, dut_ym.u_ay.ch_b_5b, dut_ym.u_ay.ch_c_5b);
		errors = errors + 1;
	end
endtask

always @(posedge clk) begin
	bdir_d <= bdir;
	quiet  <= ~bdir & ~bdir_d;
	if (check_en && hc == 4'd6 && !bdir && !bdir_d) begin
		checks = checks + 1;
		if (dut.u_ay.ch_a_raw !== ref_a || dut.u_ay.ch_b_raw !== ref_b || dut.u_ay.ch_c_raw !== ref_c)
			err("levels");
		if (dut.u_ay.f_env !== ~u_ref.f_env)
			err("f_env");
		if (cha !== ddp(ref_a) || chb !== ddp(ref_b) || chc !== ddp(ref_c))
			err("CHANNEL (DDp table)");
		if (dut_ym.u_ay.ch_a_5b[4:1] !== dut.u_ay.ch_a_raw || dut_ym.u_ay.ch_b_5b[4:1] !== dut.u_ay.ch_b_raw ||
		    dut_ym.u_ay.ch_c_5b[4:1] !== dut.u_ay.ch_c_raw)
			err("YM 5-bit levels");
		if ((dut.u_ay.r8[4] | dut.u_ay.r9[4] | dut.u_ay.r10[4]) && dut.u_ay.env_en)
			env_checks = env_checks + 1;
	end
end

// a write as turbosound gives it: the address one clock, then the data one clock; the model the same,
// its pulse from 10 ns after the clock edge to 10 ns before the next one: ay38910_silicon takes a
// write and a count of the same edge as the write first (the bypass to the comparators), a write in
// the clock after an AY clock edge as after it; the model has the same order so (its F1 and CNT_CLK
// change a few gate delays after the AY clock edge: a pulse on that edge would race them)
task automatic set_addr;
	input [7:0] a;
	begin
		@(posedge clk);
		di <= a; bdir <= 1'b1; bc <= 1'b1;
		#10 m_bdir <= 1'b1; m_bc1 <= 1'b1;
		#20 m_bdir <= 1'b0; m_bc1 <= 1'b0;
		@(posedge clk);
		bdir <= 1'b0; bc <= 1'b1;
	end
endtask

task automatic put_data;
	input [7:0] v;
	begin
		@(posedge clk);
		di <= v; bdir <= 1'b1; bc <= 1'b0;
		#10 m_bdir <= 1'b1; m_bc1 <= 1'b0;
		#20 m_bdir <= 1'b0; m_bc1 <= 1'b0;
		@(posedge clk);
		bdir <= 1'b0; bc <= 1'b1;
	end
endtask

task automatic wr;
	input [7:0] a;
	input [7:0] v;
	begin
		set_addr(a);
		repeat ({$random} % 4) @(posedge clk);
		put_data(v);
	end
endtask

// the data pulse at phase ph (0..127) of the clk / 8 period: clk_div ph[6:4], ph[3:0] clocks after its count
task automatic wr_at;
	input [7:0] a;
	input [7:0] v;
	input [6:0] ph;
	begin
		set_addr(a);
		@(posedge clk);
		while (!(ce_p && dut.u_ay.clk_div == ph[6:4])) @(posedge clk);
		// the data pulse starts at this edge + ph[3:0] clocks (put_data waits one edge)
		repeat (ph[3:0]) @(posedge clk);
		di <= v; bdir <= 1'b1; bc <= 1'b0;
		#10 m_bdir <= 1'b1; m_bc1 <= 1'b0;
		#20 m_bdir <= 1'b0; m_bc1 <= 1'b0;
		@(posedge clk);
		bdir <= 1'b0; bc <= 1'b1;
	end
endtask

// read register a from both: kg_ym2149 in its idle read state, the model by a read cycle on a free bus
task automatic rd_check;
	input [3:0] a;
	begin
		set_addr({4'd0, a});
		@(posedge clk);
		da_en <= 1'b0;
		@(posedge clk);
		m_bc1 <= 1'b1;  // {bdir, bc2, bc1} = 011
		@(posedge clk);
		@(posedge clk);
		if (da_bus !== do_ay || do_ym !== do_ay) begin
			if (errors < 20) $display("ERROR %0t: read R%0d: ref %h ay %h ym %h", $time, a, da_bus, do_ay, do_ym);
			errors = errors + 1;
		end
		m_bc1 <= 1'b0;
		@(posedge clk);
		da_en <= 1'b1;
	end
endtask

task wait_ay;
	input integer n;
	integer k;
	begin
		for (k = 0; k < n; k = k + 1) @(posedge ay_clk);
	end
endtask

task automatic read_all;
	integer r;
	begin
		for (r = 0; r < 16; r = r + 1) rd_check(r[3:0]);
	end
endtask

// a random register write; periods kept short so that the counters wrap often
task automatic rnd_write;
	reg [3:0] a;
	reg [7:0] v;
	begin
		a = $random;
		v = $random;
		case (a)
			4'd0, 4'd2, 4'd4: v = ({$random} % 8 == 0) ? v : v[5:0];
			4'd1, 4'd3, 4'd5: v = ({$random} % 8 == 0) ? v : {v[7:4], 4'd0};
			4'd11:            v = ({$random} % 8 == 0) ? v : v[3:0];
			4'd12:            v = ({$random} % 16 == 0) ? {7'd0, v[0]} : 8'd0;
			default: ;
		endcase
		wr({4'd0, a}, v);
	end
endtask

integer i, ph, n_wr;
initial begin
	if (!$value$plusargs("n=%d", n_wr)) n_wr = 300;
	rst = 1'b1;
	repeat (100) @(posedge clk);
	// the reset ends 3 clocks after an AY clock edge (as the testbench of Activator RFG), t = 0
	@(posedge clk);
	while (!ce_p) @(posedge clk);
	repeat (3) @(posedge clk);
	rst <= 1'b0;
	@(posedge clk);
	while (!ce_p) @(posedge clk);
	wait_ay(4);
	check_en = 1'b1;
	read_all;

	// tones, noise, envelope: a fixed start, then random writes at random phases
	wr(8'd7, 8'h38); wr(8'd8, 8'd15); wr(8'd9, 8'd12); wr(8'd10, 8'h10);
	wr(8'd0, 8'd1); wr(8'd2, 8'd3); wr(8'd4, 8'd5); wr(8'd11, 8'd2); wr(8'd13, 8'h0E);
	wait_ay(300);
	for (i = 0; i < n_wr; i = i + 1) begin
		rnd_write;
		repeat ({$random} % 600) @(posedge clk);
		if (i % 200 == 199) read_all;
	end
	read_all;

	// R13 at each of the 128 phases, envelope periods 0..3, all channels on the envelope
	wr(8'd7, 8'h3F); wr(8'd8, 8'h10); wr(8'd9, 8'h10); wr(8'd10, 8'h10); wr(8'd12, 8'd0);
	for (ph = 0; ph < 128 * 4; ph = ph + 1) begin
		if (ph % 128 == 0) wr(8'd11, ph / 128);
		wr_at(8'd13, (ph % 2) ? 8'h0E : 8'h0A, ph[6:0]);
		wait_ay(40 + {$random} % 40);
	end
	// tone and noise periods at each phase
	wr(8'd7, 8'h30); wr(8'd8, 8'd15); wr(8'd9, 8'd15); wr(8'd10, 8'd15);
	for (ph = 0; ph < 128; ph = ph + 1) begin
		wr_at(8'd0, {$random} % 6, ph[6:0]);
		wait_ay(10 + {$random} % 30);
		wr_at(8'd6, {$random} % 4, ph[6:0]);
		wait_ay(10 + {$random} % 30);
	end
	read_all;

	$display("tb_ay_diff: %0d checks (%0d with the envelope), %0d errors", checks, env_checks, errors);
	$display("tb_ay_diff: %0d errors", errors);
	$finish;
end

endmodule
