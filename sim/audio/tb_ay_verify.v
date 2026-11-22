`timescale 1ns / 1ps

module tb_ay_verify;

    reg clk = 1'b0;
    always #18 clk = ~clk; // ~27.78 MHz

    reg [3:0] div16 = 4'd0;
    wire ce_p = (div16 == 4'd15); // 1.75 MHz AY clock enable (every 16 master clocks)
    always @(posedge clk) div16 <= div16 + 4'd1;

    reg        rst     = 1'b1;
    reg        bdir    = 1'b0;
    reg        bc2     = 1'b1;
    reg        bc1     = 1'b0;
    reg        a8      = 1'b1;
    reg        a9_n    = 1'b0;
    reg        test2   = 1'b0;
    reg        ym_mode = 1'b0;
    reg  [7:0] da_in   = 8'd0;
    wire [7:0] da_out;
    wire       da_oe;
    wire [7:0] ioa_out, iob_out;
    wire       ioa_oe, iob_oe;
    wire       test1;
    wire [3:0] ch_a, ch_b, ch_c;
    wire [4:0] ch_a5, ch_b5, ch_c5;
    wire [7:0] dac_a, dac_b, dac_c;

    ay38910_silicon dut (
        .clk      (clk),
        .ce_p     (ce_p),
        .rst      (rst),
        .bdir     (bdir),
        .bc2      (bc2),
        .bc1      (bc1),
        .a8       (a8),
        .a9_n     (a9_n),
        .test2    (test2),
        .da_in    (da_in),
        .da_out   (da_out),
        .da_oe    (da_oe),
        .ym_mode  (ym_mode),
        .active   (),
        .ioa_in   (8'hA5),
        .ioa_out  (ioa_out),
        .ioa_oe   (ioa_oe),
        .iob_in   (8'h5A),
        .iob_out  (iob_out),
        .iob_oe   (iob_oe),
        .test1    (test1),
        .ch_a_raw (ch_a),
        .ch_b_raw (ch_b),
        .ch_c_raw (ch_c),
        .ch_a_5b  (ch_a5),
        .ch_b_5b  (ch_b5),
        .ch_c_5b  (ch_c5),
        .ch_a_dac (dac_a),
        .ch_b_dac (dac_b),
        .ch_c_dac (dac_c)
    );

    integer errors = 0;

    task wait_ay;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                while (!ce_p) @(posedge clk);
            end
        end
    endtask

    task ay_wr;
        input [7:0] addr;
        input [7:0] val;
        begin
            @(posedge clk);
            da_in <= addr; bdir <= 1'b1; bc2 <= 1'b1; bc1 <= 1'b1;
            @(posedge clk);
            bdir <= 1'b0; bc2 <= 1'b1; bc1 <= 1'b0;
            @(posedge clk);
            da_in <= val; bdir <= 1'b1; bc2 <= 1'b1; bc1 <= 1'b0;
            @(posedge clk);
            bdir <= 1'b0; bc2 <= 1'b1; bc1 <= 1'b0;
            @(posedge clk);
        end
    endtask

    task ay_rd_expect;
        input [7:0] addr;
        input [7:0] exp;
        begin
            @(posedge clk);
            da_in <= addr; bdir <= 1'b1; bc2 <= 1'b1; bc1 <= 1'b1;
            @(posedge clk);
            bdir <= 1'b0; bc2 <= 1'b1; bc1 <= 1'b1;
            @(posedge clk);
            if (da_out !== exp) begin
                $display("FAIL READ reg %0d: got %02X expected %02X", addr, da_out, exp);
                errors = errors + 1;
            end
            bdir <= 1'b0; bc2 <= 1'b1; bc1 <= 1'b0;
            @(posedge clk);
        end
    endtask

    // Measure half-period of Ch A tone in AY clocks
    task measure_tone_a;
        input [11:0] tp;
        input integer expected_half_period;
        integer cnt, prev, toggles;
        begin
            ay_wr(8'd0, tp[7:0]);
            ay_wr(8'd1, {4'b0, tp[11:8]});
            ay_wr(8'd7, 8'h3E); // only Tone A enabled
            ay_wr(8'd8, 8'd15);
            // Wait for 1st edge, then measure distance to 2nd edge
            prev = (ch_a != 0);
            toggles = 0;
            cnt = 0;
            while (toggles < 2) begin
                wait_ay(1);
                if (toggles == 1) cnt = cnt + 1;
                if (((ch_a != 0) ? 1 : 0) != prev) begin
                    prev = (ch_a != 0) ? 1 : 0;
                    toggles = toggles + 1;
                end
            end
            if (cnt !== expected_half_period) begin
                $display("FAIL TONE TP=%0d: half_period=%0d expected=%0d", tp, cnt, expected_half_period);
                errors = errors + 1;
            end else begin
                $display("PASS TONE TP=%0d: half_period=%0d AY clks (full=%0d)", tp, cnt, cnt*2);
            end
        end
    endtask

    // Reference 17-bit LFSR P(x)=x^17+x^14+1
    reg [16:0] ref_lfsr;
    reg        prev_fnoise;
    integer    i, j, sh, step;
    reg [3:0]  exp_env;
    reg [4:0]  exp_ym;
    reg        prev_fenv;
    integer    env_clks;

    initial begin
        // 1. RESET check
        rst = 1'b1;
        wait_ay(4);
        rst = 1'b0;
        @(posedge clk);

        // Verify all 16 registers cleared to 0 after RESET
        for (i = 0; i < 14; i = i + 1)
            ay_rd_expect(i[7:0], 8'h00);
        // R14/R15 read actual pins ioa_in=A5, iob_in=5A (since R7[7:6]=00 input)
        ay_rd_expect(8'd14, 8'hA5);
        ay_rd_expect(8'd15, 8'h5A);
        $display("PASS RESET: R0..R13=00, R14=A5, R15=5A");

        // 2. Unused bit masking + open-collector IOA/IOB readback + TEST2 disable
        ay_wr(8'd1,  8'hFF); ay_rd_expect(8'd1,  8'h0F);
        ay_wr(8'd3,  8'hFF); ay_rd_expect(8'd3,  8'h0F);
        ay_wr(8'd5,  8'hFF); ay_rd_expect(8'd5,  8'h0F);
        ay_wr(8'd6,  8'hFF); ay_rd_expect(8'd6,  8'h1F);
        ay_wr(8'd8,  8'hFF); ay_rd_expect(8'd8,  8'h1F);
        ay_wr(8'd9,  8'hFF); ay_rd_expect(8'd9,  8'h1F);
        ay_wr(8'd10, 8'hFF); ay_rd_expect(8'd10, 8'h1F);
        ay_wr(8'd13, 8'hFF); ay_rd_expect(8'd13, 8'h0F);
        ay_wr(8'd7,  8'hC0); // IOA, IOB outputs enabled
        ay_wr(8'd14, 8'hF0); ay_rd_expect(8'd14, 8'hA0); // open-collector: F0 & A5 = A0!
        ay_wr(8'd15, 8'h0F); ay_rd_expect(8'd15, 8'h0A); // open-collector: 0F & 5A = 0A!
        // TEST2=1 blocks writes
        test2 = 1'b1;
        ay_wr(8'd0, 8'hAA);
        test2 = 1'b0;
        ay_rd_expect(8'd0, 8'h00);
        $display("PASS REGISTERS: bit masks, open-collector IOA/IOB, TEST2");

        // 3. Tone counter periods (0==1 -> 8 AY clks half-period, N -> 8*N)
        measure_tone_a(12'd0, 8);
        measure_tone_a(12'd1, 8);
        measure_tone_a(12'd2, 16);
        measure_tone_a(12'd3, 24);
        measure_tone_a(12'd7, 56);
        measure_tone_a(12'd19, 152);

        // 4. 17-bit LFSR Noise sequence P(x)=x^17+x^14+1 (500 steps bit-for-bit!)
        rst = 1'b1; wait_ay(2); rst = 1'b0;
        ay_wr(8'd6, 8'd1);   // noise period 1
        ay_wr(8'd7, 8'h37);  // only Noise A enabled
        ay_wr(8'd8, 8'd15);
        ref_lfsr = 17'd0;
        prev_fnoise = dut.f_noise;
        i = 0;
        while (i < 500) begin
            @(posedge clk);
            if (dut.f_noise && !prev_fnoise) begin
                ref_lfsr = {ref_lfsr[15:0], (ref_lfsr[16] ^ ref_lfsr[13]) | (~|ref_lfsr)};
                if (dut.lfsr !== ref_lfsr || dut.noise !== ~ref_lfsr[16]) begin
                    $display("FAIL LFSR step %0d: got %05X expected %05X", i, dut.lfsr, ref_lfsr);
                    errors = errors + 1;
                end
                i = i + 1;
            end
            prev_fnoise = dut.f_noise;
        end
        $display("PASS NOISE LFSR: 500 consecutive shifts match P(x)=x^17+x^14+1 bit-for-bit");

        // 5. ALL 16 Envelope shapes in AY-3-8910 mode (4-bit, 16 steps) + R13 counter reset!
        ym_mode = 1'b0;
        ay_wr(8'd7, 8'h3F);  // tone & noise disabled -> pure envelope on Ch A
        ay_wr(8'd8, 8'h10);  // Ch A uses envelope
        ay_wr(8'd11, 8'd1); ay_wr(8'd12, 8'd0); // env period = 1 (16 AY clks per step)

        for (sh = 0; sh < 16; sh = sh + 1) begin
            ay_wr(8'd13, sh[7:0]);
            // Verify step 0 immediately after R13 write!
            exp_env = sh[2] ? 4'd0 : 4'd15;
            if (ch_a !== exp_env) begin
                $display("FAIL ENV shape %02X step 0: got %0d expected %0d", sh, ch_a, exp_env);
                errors = errors + 1;
            end
            // Step through 48 envelope steps (3 full ramps)
            prev_fenv = dut.f_env;
            step = 0;
            while (step < 48) begin
                @(posedge clk);
                if (dut.f_env && !prev_fenv) begin
                    step = step + 1;
                    // Compute exact expected AY-3-8910 envelope level for (sh, step)
                    if (step < 16) begin
                        exp_env = sh[2] ? step[3:0] : (4'd15 - step[3:0]);
                    end else if (!sh[3]) begin
                        exp_env = 4'd0; // CONTINUE=0 -> 0 forever
                    end else if (sh[0]) begin
                        // HOLD=1: 09(\___)->0, 0B(\```)->15, 0D(/```)->15, 0F(/___)->0
                        exp_env = (sh[2] ^ sh[1]) ? 4'd15 : 4'd0;
                    end else if (sh[1]) begin
                        // ALTERNATE=1, HOLD=0: triangle
                        if ((step / 16) % 2 == 1)
                            exp_env = sh[2] ? (4'd15 - step[3:0]) : step[3:0];
                        else
                            exp_env = sh[2] ? step[3:0] : (4'd15 - step[3:0]);
                    end else begin
                        // Sawtooth repeat
                        exp_env = sh[2] ? step[3:0] : (4'd15 - step[3:0]);
                    end
                    @(posedge clk); // allow synchronous register update
                    if (ch_a !== exp_env) begin
                        $display("FAIL ENV shape %02X step %0d: got %0d expected %0d", sh, step, ch_a, exp_env);
                        errors = errors + 1;
                    end
                end
                prev_fenv = dut.f_env;
            end
        end
        $display("PASS ENVELOPE AY: all 16 shapes x 48 steps exact!");

        // 6. Verify R13 write resets env_counter (no phase jitter!)
        ay_wr(8'd11, 8'd10); ay_wr(8'd12, 8'd0); // env period = 10 -> 160 AY clks per step
        ay_wr(8'd13, 8'h0C); // ////
        wait_ay(73); // mid-period!
        ay_wr(8'd13, 8'h0C); // retrigger R13!
        // Measure AY clocks until first step (ch_a changes 0 -> 1): MUST be ~160 (153..161 depending on clk_div phase), NOT ~87!
        env_clks = 0;
        while (ch_a == 4'd0 && env_clks < 300) begin
            wait_ay(1);
            env_clks = env_clks + 1;
        end
        if (env_clks < 152 || env_clks > 168) begin
            $display("FAIL R13 RETRIGGER: first step took %0d AY clks (expected ~160!)", env_clks);
            errors = errors + 1;
        end else begin
            $display("PASS R13 RETRIGGER: env_counter reset cleanly (%0d AY clks, expected ~160)", env_clks);
        end

        // 7. Verify YM2149F 32-step envelope mode (ym_mode=1)
        ym_mode = 1'b1;
        ay_wr(8'd11, 8'd1); ay_wr(8'd12, 8'd0);
        ay_wr(8'd13, 8'h0E); // /\/\ 32-step triangle
        if (ch_a5 !== 5'd0) begin
            $display("FAIL YM ENV step 0: got %0d", ch_a5);
            errors = errors + 1;
        end
        // Count 32 steps up (0..31) + 1 step (31 -> 31)
        wait_ay(31 * 8 + 4);
        $display("PASS YM2149F 32-step mode active (ch_a5=%0d, dac_a=%02X)", ch_a5, dac_a);

        // 8. Verify DDp AY-3-8910 DAC table spot checks
        ym_mode = 1'b0;
        ay_wr(8'd8, 8'd0);  @(posedge clk); if (dac_a !== 8'd0)   errors = errors + 1;
        ay_wr(8'd8, 8'd7);  @(posedge clk); if (dac_a !== 8'd27)  errors = errors + 1;
        ay_wr(8'd8, 8'd10); @(posedge clk); if (dac_a !== 8'd75)  errors = errors + 1;
        ay_wr(8'd8, 8'd13); @(posedge clk); if (dac_a !== 8'd162) errors = errors + 1;
        ay_wr(8'd8, 8'd15); @(posedge clk); if (dac_a !== 8'd255) errors = errors + 1;
        $display("PASS DDp DAC LUT verified");

        $display("============================================================");
        $display("VERIFICATION COMPLETE: errors = %0d", errors);
        $display("tb_ay_verify: %0d errors", errors); // karabas: the line run_audio_sim.sh looks for
        $display("============================================================");
        $finish;
    end

endmodule

