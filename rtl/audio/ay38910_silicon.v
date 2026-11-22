// karabas: no `timescale, as the kg_* modules (verilator TIMESCALEMOD on kg_ym2149)
// ==============================================================================
//
// Project: AY-3-8910 Silicon-to-RTL Synchronous Core (with optional YM2149F mode)
//
// Description:
//   Fully synchronous, latch-free FPGA RTL implementation of the GI AY-3-8910
//   Programmable Sound Generator, derived directly from:
//     - Transistor-level reverse engineering by deathsoft (2019)
//     - Synchronous logic schematic (rev 10) by Andrey Titov / dr.Titus (2025)
//     - Cycle-verified against lvd2/ay-3-8910_reverse_engineered (ay_model.v)
//
//   Features faithful to the AY-3-8910 silicon:
//     - Exact clk/8 prescaler (F1, CNT_CLK) and reset phase
//     - 3x 12-bit tone counters with >= comparator (period 0 == period 1)
//     - 5-bit noise period counter + F_NOISE /2 + 17-bit LFSR P(x)=x^17+x^14+1
//     - 16-bit envelope period counter + F_ENV /2 (also exposed on test1)
//     - Exact R13 (octal R15) write reset of envelope counter, F_ENV, and FSM
//     - Exact 4-bit envelope wave counter + HOLD / ALT / CONT flip-flops
//     - Exact RESET behavior: all 16 registers R0..R15 cleared to 0, all
//       counters/LFSR/prescaler/envelope cleared, tone/noise/f_env initialized
//     - Immediate register update on master clk (emulating transparent latches)
//     - Unused register bits read back as 0; IOA/IOB read actual pin state
//     - Measured AY-3-8910 non-linear DAC table (DDp) + optional YM2149F mode
//       (ym_mode=1: 32-step envelope at F1 rate + YM2149F DAC table)
//
// ==============================================================================

module ay38910_silicon
(
    input  wire       clk,        // High-frequency FPGA master clock (e.g. 28 MHz)
    input  wire       ce_p,       // Rising-edge enable of AY CLK (e.g. 1.75 MHz)
    input  wire       rst,        // Synchronous active-high reset (chip /RST=0)

    // Bus control (GI AY-3-8910 pins)
    input  wire       bdir,
    input  wire       bc2,
    input  wire       bc1,
    input  wire       a8,
    input  wire       a9_n,       // /A9 (active low)
    input  wire       test2,      // Undocumented /CS disable when 1

    input  wire [7:0] da_in,
    output wire [7:0] da_out,
    output wire       da_oe,      // 1 when driving DA bus (Read from PSG)

    // Optional mode select (0 = pure AY-3-8910 silicon, 1 = YM2149F 32-step env)
    input  wire       ym_mode,

    // GPIO ports (open-collector with pull-ups externally)
    input  wire [7:0] ioa_in,
    output wire [7:0] ioa_out,
    output wire       ioa_oe,
    input  wire [7:0] iob_in,
    output wire [7:0] iob_out,
    output wire       iob_oe,

    // Undocumented TEST1 output (= F_ENV)
    output wire       test1,

    // Raw 4-bit logical levels (0..15, exact AY-3-8910 DAC codes)
    output wire [3:0] ch_a_raw,
    output wire [3:0] ch_b_raw,
    output wire [3:0] ch_c_raw,

    // 5-bit logical levels (for YM2149F 32-step mode; in AY mode = {raw, raw[3]})
    output wire [4:0] ch_a_5b,
    output wire [4:0] ch_b_5b,
    output wire [4:0] ch_c_5b,

    // Active channel flags (~R7[5:0])
    output wire [5:0] active,

    // 8-bit DAC-mapped audio outputs (DDp AY table / YM2149F table)
    output wire [7:0] ch_a_dac,
    output wire [7:0] ch_b_dac,
    output wire [7:0] ch_c_dac
);

    // =========================================================================
    // 1. I/O CONTROL LOGIC (dr.Titus rev 10: U114, U15-U18, U1, U56-U61)
    // =========================================================================
    wire psg_cs = a8 & ~a9_n & ~(|da_in[7:4]);

    // Latch Address patterns: {bdir, bc2, bc1} in {001, 111, 100}
    wire latch_addr = (~bdir & ~bc2 &  bc1) |
                      ( bdir &  bc2 &  bc1) |
                      ( bdir & ~bc2 & ~bc1);

    wire write_psg  = ( bdir &  bc2 & ~bc1) & ~test2;
    wire read_psg   = (~bdir &  bc2 &  bc1) & ~test2;

    reg        psg_sel = 1'b0;
    reg  [3:0] reg_addr = 4'd0;

    // On master clk: track transparent address latch & chip select
    always @(posedge clk) begin
        if (rst) begin
            psg_sel  <= 1'b0;
            reg_addr <= 4'd0;
        end else if (latch_addr) begin
            psg_sel <= psg_cs;
            if (psg_cs)
                reg_addr <= da_in[3:0];
        end
    end

    // Active chip select during write/read (combinational lookahead if latch_addr just fell)
    // karabas: reg_wr is not used (wr_en below); kg_ym2149 is linted with -Wall
    /* verilator lint_off UNUSEDSIGNAL */
    wire reg_wr = (write_psg & psg_sel) | rst;
    /* verilator lint_on UNUSEDSIGNAL */
    assign da_oe = read_psg & psg_sel & ~rst;

    // =========================================================================
    // 2. REGISTERS (dr.Titus rev 10: REG_0..REG_17, octal -> decimal 0..15)
    //    Emulated on high-speed master clk; combinational bypass gives
    //    zero-cycle comparator visibility matching transparent silicon latches.
    // =========================================================================
    reg [7:0] r0  = 8'd0; // Ch A Tone Period L
    reg [3:0] r1  = 4'd0; // Ch A Tone Period H
    reg [7:0] r2  = 8'd0; // Ch B Tone Period L
    reg [3:0] r3  = 4'd0; // Ch B Tone Period H
    reg [7:0] r4  = 8'd0; // Ch C Tone Period L
    reg [3:0] r5  = 4'd0; // Ch C Tone Period H
    reg [4:0] r6  = 5'd0; // Noise Period
    reg [7:0] r7  = 8'd0; // Mixer Control / I/O Enable
    reg [4:0] r8  = 5'd0; // Ch A Amplitude (octal R10)
    reg [4:0] r9  = 5'd0; // Ch B Amplitude (octal R11)
    reg [4:0] r10 = 5'd0; // Ch C Amplitude (octal R12)
    reg [7:0] r11 = 8'd0; // Envelope Period L (octal R13)
    reg [7:0] r12 = 8'd0; // Envelope Period H (octal R14)
    reg [3:0] r13 = 4'd0; // Envelope Shape    (octal R15)
    reg [7:0] r14 = 8'd0; // Port A            (octal R16)
    reg [7:0] r15 = 8'd0; // Port B            (octal R17)

    wire wr_en = write_psg & psg_sel & ~rst;

    always @(posedge clk) begin
        if (rst) begin
            // Silicon RESET selects all 16 registers and writes 0 to every register
            r0  <= 8'd0;
            r1  <= 4'd0;
            r2  <= 8'd0;
            r3  <= 4'd0;
            r4  <= 8'd0;
            r5  <= 4'd0;
            r6  <= 5'd0;
            r7  <= 8'd0;
            r8  <= 5'd0;
            r9  <= 5'd0;
            r10 <= 5'd0;
            r11 <= 8'd0;
            r12 <= 8'd0;
            r13 <= 4'd0;
            r14 <= 8'd0;
            r15 <= 8'd0;
        end else if (wr_en) begin
            case (reg_addr)
                4'd0:  r0  <= da_in;
                4'd1:  r1  <= da_in[3:0];
                4'd2:  r2  <= da_in;
                4'd3:  r3  <= da_in[3:0];
                4'd4:  r4  <= da_in;
                4'd5:  r5  <= da_in[3:0];
                4'd6:  r6  <= da_in[4:0];
                4'd7:  r7  <= da_in;
                4'd8:  r8  <= da_in[4:0];
                4'd9:  r9  <= da_in[4:0];
                4'd10: r10 <= da_in[4:0];
                4'd11: r11 <= da_in;
                4'd12: r12 <= da_in;
                4'd13: r13 <= da_in[3:0];
                4'd14: r14 <= da_in;
                4'd15: r15 <= da_in;
            endcase
        end
    end

    // Transparent-latch effective values (for comparators / envelope during write)
    wire [7:0] eff_r0  = (wr_en && reg_addr == 4'd0 ) ? da_in      : r0;
    wire [3:0] eff_r1  = (wr_en && reg_addr == 4'd1 ) ? da_in[3:0] : r1;
    wire [7:0] eff_r2  = (wr_en && reg_addr == 4'd2 ) ? da_in      : r2;
    wire [3:0] eff_r3  = (wr_en && reg_addr == 4'd3 ) ? da_in[3:0] : r3;
    wire [7:0] eff_r4  = (wr_en && reg_addr == 4'd4 ) ? da_in      : r4;
    wire [3:0] eff_r5  = (wr_en && reg_addr == 4'd5 ) ? da_in[3:0] : r5;
    wire [4:0] eff_r6  = (wr_en && reg_addr == 4'd6 ) ? da_in[4:0] : r6;
    wire [7:0] eff_r11 = (wr_en && reg_addr == 4'd11) ? da_in      : r11;
    wire [7:0] eff_r12 = (wr_en && reg_addr == 4'd12) ? da_in      : r12;
    wire [3:0] eff_r13 = (wr_en && reg_addr == 4'd13) ? da_in[3:0] : r13;

    wire [11:0] period_a = {eff_r1, eff_r0};
    wire [11:0] period_b = {eff_r3, eff_r2};
    wire [11:0] period_c = {eff_r5, eff_r4};
    wire [4:0]  period_n = eff_r6;
    wire [15:0] period_e = {eff_r12, eff_r11};

    // GPIO outputs (open-collector semantics; read always sees actual pin state)
    assign active  = ~r7[5:0];
    assign ioa_out = r14;
    assign ioa_oe  = r7[6];
    assign iob_out = r15;
    assign iob_oe  = r7[7];

    // =========================================================================
    // 3. READ MULTIPLEXER (unused bits read as 0; R14/R15 read actual IO pins)
    // =========================================================================
    reg [7:0] rdata;
    always @* begin
        case (reg_addr)
            4'd0:  rdata = r0;
            4'd1:  rdata = {4'b0000, r1};
            4'd2:  rdata = r2;
            4'd3:  rdata = {4'b0000, r3};
            4'd4:  rdata = r4;
            4'd5:  rdata = {4'b0000, r5};
            4'd6:  rdata = {3'b000,  r6};
            4'd7:  rdata = r7;
            4'd8:  rdata = {3'b000,  r8};
            4'd9:  rdata = {3'b000,  r9};
            4'd10: rdata = {3'b000,  r10};
            4'd11: rdata = r11;
            4'd12: rdata = r12;
            4'd13: rdata = {4'b0000, r13};
            4'd14: rdata = r7[6] ? (r14 & ioa_in) : ioa_in;
            4'd15: rdata = r7[7] ? (r15 & iob_in) : iob_in;
        endcase
    end
    assign da_out = da_oe ? rdata : 8'hFF;

    // =========================================================================
    // 4. CLOCK GENERATOR (dr.Titus rev 10: U3 3-bit counter, U2 CNT_CLK)
    //    clk_div: 0, 1, 2, 3 (CNT_CLK=1), 4 (F1 rises), 5, 6, 7, 0 (F1 falls)
    // =========================================================================
    reg [2:0] clk_div = 3'd0;

    // CNT_CLK is high during clk_div == 3'b011; F1 rises on ce_p when clk_div == 3'b011
    wire cnt_clk = (clk_div == 3'b011);
    wire f1      = clk_div[2];
    wire f1_rise = ce_p && (clk_div == 3'b011);

    always @(posedge clk) begin
        if (rst)
            clk_div <= 3'd0;
        else if (ce_p)
            clk_div <= clk_div + 3'd1;
    end

    // =========================================================================
    // 5. TONE COUNTERS A, B, C (dr.Titus rev 10: CTR_CH_x, CMP_CH_x, U6-U8, U95/U98/U102)
    //    SR latch U8/U7/U6 sets when (cnt >= period) & CNT_CLK (or RST),
    //    clearing counter to 0 and toggling TONE_x on 0->1 edge of TC_x_RST.
    //    On F1 rising edge (clk_div 3->4), U8/U7/U6 clears and counter counts +1.
    // =========================================================================
    reg [11:0] cnt_a = 12'd0;
    reg [11:0] cnt_b = 12'd0;
    reg [11:0] cnt_c = 12'd0;

    reg tc_a_rst = 1'b1;
    reg tc_b_rst = 1'b1;
    reg tc_c_rst = 1'b1;

    reg tone_a = 1'b1;
    reg tone_b = 1'b1;
    reg tone_c = 1'b1;

    wire cmp_a = (cnt_a >= period_a);
    wire cmp_b = (cnt_b >= period_b);
    wire cmp_c = (cnt_c >= period_c);

    // Channel A
    always @(posedge clk) begin
        if (rst) begin
            cnt_a    <= 12'd0;
            tc_a_rst <= 1'b1;
            tone_a   <= 1'b1;
        end else begin
            if (f1_rise) begin
                // End of CNT_CLK / start of F1=1: SR resets, counter increments from (cleared 0 -> 1 or cnt+1)
                if (tc_a_rst || cmp_a) begin
                    if (!tc_a_rst) tone_a <= ~tone_a;
                    cnt_a    <= 12'd1;
                    tc_a_rst <= 1'b0;
                end else begin
                    cnt_a    <= cnt_a + 12'd1;
                    tc_a_rst <= 1'b0;
                end
            end else if (cnt_clk && cmp_a && !tc_a_rst) begin
                // Mid-CNT_CLK hit (including transparent register write): latch set, clear counter, toggle tone
                tc_a_rst <= 1'b1;
                cnt_a    <= 12'd0;
                tone_a   <= ~tone_a;
            end
        end
    end

    // Channel B
    always @(posedge clk) begin
        if (rst) begin
            cnt_b    <= 12'd0;
            tc_b_rst <= 1'b1;
            tone_b   <= 1'b1;
        end else begin
            if (f1_rise) begin
                if (tc_b_rst || cmp_b) begin
                    if (!tc_b_rst) tone_b <= ~tone_b;
                    cnt_b    <= 12'd1;
                    tc_b_rst <= 1'b0;
                end else begin
                    cnt_b    <= cnt_b + 12'd1;
                    tc_b_rst <= 1'b0;
                end
            end else if (cnt_clk && cmp_b && !tc_b_rst) begin
                tc_b_rst <= 1'b1;
                cnt_b    <= 12'd0;
                tone_b   <= ~tone_b;
            end
        end
    end

    // Channel C
    always @(posedge clk) begin
        if (rst) begin
            cnt_c    <= 12'd0;
            tc_c_rst <= 1'b1;
            tone_c   <= 1'b1;
        end else begin
            if (f1_rise) begin
                if (tc_c_rst || cmp_c) begin
                    if (!tc_c_rst) tone_c <= ~tone_c;
                    cnt_c    <= 12'd1;
                    tc_c_rst <= 1'b0;
                end else begin
                    cnt_c    <= cnt_c + 12'd1;
                    tc_c_rst <= 1'b0;
                end
            end else if (cnt_clk && cmp_c && !tc_c_rst) begin
                tc_c_rst <= 1'b1;
                cnt_c    <= 12'd0;
                tone_c   <= ~tone_c;
            end
        end
    end

    // =========================================================================
    // 6. NOISE COUNTER + 17-BIT LFSR (dr.Titus rev 10: CTR_NOISE, U5, U103, U27-U52)
    //    Polynomial: P(x) = x^17 + x^14 + 1  (lfsr[16] ^ lfsr[13] | zero_det)
    //    NOISE = ~lfsr[16]
    // =========================================================================
    reg [4:0]  cnt_n   = 5'd0;
    reg        nc_rst  = 1'b1;
    reg        f_noise = 1'b1;
    reg [16:0] lfsr    = 17'd0;

    wire cmp_n = (cnt_n >= period_n);
    wire lfsr_zero = ~(|lfsr);
    wire lfsr_fb   = (lfsr[16] ^ lfsr[13]) | lfsr_zero;
    wire noise     = ~lfsr[16];

    wire noise_toggle_now = (!rst) && (
        (f1_rise && !nc_rst && cmp_n) ||
        (!f1_rise && cnt_clk && cmp_n && !nc_rst)
    );
    // Rising edge of F_NOISE occurs when f_noise transitions 0 -> 1
    wire f_noise_rise = noise_toggle_now && (~f_noise);

    always @(posedge clk) begin
        if (rst) begin
            cnt_n   <= 5'd0;
            nc_rst  <= 1'b1;
            f_noise <= 1'b1;
            lfsr    <= 17'd0;
        end else begin
            if (f1_rise) begin
                if (nc_rst || cmp_n) begin
                    if (!nc_rst) f_noise <= ~f_noise;
                    cnt_n  <= 5'd1;
                    nc_rst <= 1'b0;
                end else begin
                    cnt_n  <= cnt_n + 5'd1;
                    nc_rst <= 1'b0;
                end
            end else if (cnt_clk && cmp_n && !nc_rst) begin
                nc_rst  <= 1'b1;
                cnt_n   <= 5'd0;
                f_noise <= ~f_noise;
            end

            if (f_noise_rise)
                lfsr <= {lfsr[15:0], lfsr_fb};
        end
    end

    // =========================================================================
    // 7. ENVELOPE COUNTER & ENVELOPE GENERATOR (dr.Titus rev 10: U4, U106, U42-U66)
    //    ENV_RST = (REG_WR & SEL_R15) -> write to decimal R13 OR chip RST!
    //    Resets BOTH env period counter, F_ENV, and envelope wave FSM.
    //    In pure AY-3-8910 mode (ym_mode=0): 4-bit wave stepped on F_ENV rising edge.
    //    In YM2149F mode (ym_mode=1): 5-bit wave stepped on every F_ENV edge (2x rate).
    // =========================================================================
    wire env_rst = rst | (wr_en && (reg_addr == 4'd13));

    reg [15:0] cnt_e  = 16'd0;
    reg        ec_rst = 1'b1;
    reg        f_env  = 1'b1;

    wire cmp_e = (cnt_e >= period_e);

    wire f_env_toggle = (!env_rst) && (
        (f1_rise && !ec_rst && cmp_e) ||
        (!f1_rise && cnt_clk && cmp_e && !ec_rst)
    );
    // In AY-3-8910, envelope wave steps on rising edge of F_ENV (0->1)
    wire env_step_ay = f_env_toggle && (~f_env);
    // In YM2149F, envelope wave steps at 2x rate (every edge of F_ENV)
    wire env_step    = ym_mode ? f_env_toggle : env_step_ay;

    // karabas: the envelope period counter after ENV_RST as in the transistor-level model of lvd2
    // (sim/audio/tb_ay_diff.v; one clk/8 tick = 8 AY clocks). Its bit 0 is a two-phase flip-flop
    // whose first stage has no reset (ay_model_counter, UP_RST(0)): ENV_RST while F1 = 1 clears the
    // counter only for the write, U4 is cleared at once, and bit 0 comes back from that stage, so
    // the count goes on from cnt_e[0], not from 1 (as the code came; with a period of 2 or more the
    // envelope began a tick early or late, depending on the count before). An ENV_RST that ends
    // at the edge where F1 rises is a write just before it (F1 = 0), counted at that rise: 1 (it
    // waited for the next rise).
    always @(posedge clk) begin
        if (env_rst) begin
            // U4 SR-latch has R = F1, S = ENV_RST | (CMP_ENV & CNT_CLK):
            // if ENV_RST finishes while F1=1, R=1 immediately clears U4 (ec_rst=0).
            if (rst) begin
                cnt_e  <= 16'd0;
                ec_rst <= 1'b1;
            end else if (f1_rise) begin
                cnt_e  <= 16'd1;
                ec_rst <= 1'b0;
            end else if (f1) begin
                cnt_e  <= {15'd0, cnt_e[0]};
                ec_rst <= 1'b0;
            end else begin
                cnt_e  <= 16'd0;
                ec_rst <= 1'b1;
            end
            f_env  <= 1'b1;
        end else begin
            if (f1_rise) begin
                if (ec_rst || cmp_e) begin
                    if (!ec_rst) f_env <= ~f_env;
                    cnt_e  <= 16'd1;
                    ec_rst <= 1'b0;
                end else begin
                    cnt_e  <= cnt_e + 16'd1;
                    ec_rst <= 1'b0;
                end
            end else if (cnt_clk && cmp_e && !ec_rst) begin
                ec_rst <= 1'b1;
                cnt_e  <= 16'd0;
                f_env  <= ~f_env;
            end
        end
    end

    assign test1 = f_env;

    // Envelope Wave Generator (4-bit for AY, 5-bit for YM2149F)
    reg [4:0] env_wave = 5'd0; // AY uses [3:0]; YM uses [4:0]
    reg       env_hold = 1'b0;
    reg       env_alt  = 1'b0;
    reg       env_cont = 1'b0;

    wire env_en  = ~env_cont | eff_r13[3]; // CONTINUE
    wire env_inv = ~(env_alt ^ eff_r13[2]); // ATTACK / ~DECAY (U62 XNOR)

    wire wave_top = ym_mode ? (&env_wave[4:0]) : (&env_wave[3:0]);

    always @(posedge clk) begin
        if (env_rst) begin
            env_wave <= 5'd0;
            env_hold <= 1'b0;
            env_alt  <= 1'b0;
            env_cont <= 1'b0;
        end else if (env_step && !env_hold) begin
            if (wave_top) begin
                // Falling edge of MSB (Q3 in AY / Q4 in YM): U63, U64, U65 trigger
                if (eff_r13[1]) env_alt  <= ~env_alt; // ALTERNATE
                if (env_en)     env_cont <= ~env_cont; // CONTINUE=0 latches env_cont=1 -> env_en=0
                if (eff_r13[0]) begin
                    // HOLD=1: REG_HOLD sets -> forces wave counter SET = all 1s
                    env_hold <= 1'b1;
                    env_wave <= 5'b11111;
                end else begin
                    env_wave <= 5'd0;
                end
            end else begin
                env_wave <= env_wave + 5'd1;
            end
        end
    end

    // Output of XOR_INV_ENV and BUF_ENV
    wire [3:0] env_ay_4b = env_en ? (env_wave[3:0] ^ {4{env_inv}}) : 4'd0;
    wire [4:0] env_ym_5b = env_en ? (env_wave[4:0] ^ {5{env_inv}}) : 5'd0;

    // =========================================================================
    // 8. TONE/NOISE MIX & CHANNEL VOLUME MUX (dr.Titus rev 10: U88-U113, MUX_CH_x)
    // =========================================================================
    wire snd_a = (tone_a | r7[0]) & (noise | r7[3]);
    wire snd_b = (tone_b | r7[1]) & (noise | r7[4]);
    wire snd_c = (tone_c | r7[2]) & (noise | r7[5]);

    assign ch_a_raw = snd_a ? (r8[4]  ? env_ay_4b : r8[3:0] ) : 4'd0;
    assign ch_b_raw = snd_b ? (r9[4]  ? env_ay_4b : r9[3:0] ) : 4'd0;
    assign ch_c_raw = snd_c ? (r10[4] ? env_ay_4b : r10[3:0]) : 4'd0;

    // 5-bit logical level for YM mode (or {raw, 1'b0} / {raw, raw[3]} for AY)
    assign ch_a_5b = ym_mode ? (snd_a ? (r8[4]  ? env_ym_5b : {r8[3:0],  |r8[3:0] }) : 5'd0) : {ch_a_raw, 1'b0};
    assign ch_b_5b = ym_mode ? (snd_b ? (r9[4]  ? env_ym_5b : {r9[3:0],  |r9[3:0] }) : 5'd0) : {ch_b_raw, 1'b0};
    assign ch_c_5b = ym_mode ? (snd_c ? (r10[4] ? env_ym_5b : {r10[3:0], |r10[3:0]}) : 5'd0) : {ch_c_raw, 1'b0};

    // =========================================================================
    // 9. DAC TABLES
    //    AY-3-8910: Measured non-linear volumes by DDp (from dr.Titus rev 10):
    //      0.00, 0.99, 1.43, 2.08, 3.05, 4.57, 6.46, 10.63,
    //      12.79, 20.57, 29.35, 37.23, 49.27, 63.54, 80.55, 100.00 (%)
    //    YM2149F: Standard 32-step logarithmic curve
    // =========================================================================
    function [7:0] ay_dac_lut;
        input [3:0] lvl;
        begin
            case (lvl)
                4'd0:  ay_dac_lut = 8'd0;   //   0.00%
                4'd1:  ay_dac_lut = 8'd3;   //   0.99%
                4'd2:  ay_dac_lut = 8'd4;   //   1.43%
                4'd3:  ay_dac_lut = 8'd5;   //   2.08%
                4'd4:  ay_dac_lut = 8'd8;   //   3.05%
                4'd5:  ay_dac_lut = 8'd12;  //   4.57%
                4'd6:  ay_dac_lut = 8'd16;  //   6.46%
                4'd7:  ay_dac_lut = 8'd27;  //  10.63%
                4'd8:  ay_dac_lut = 8'd33;  //  12.79%
                4'd9:  ay_dac_lut = 8'd52;  //  20.57%
                4'd10: ay_dac_lut = 8'd75;  //  29.35%
                4'd11: ay_dac_lut = 8'd95;  //  37.23%
                4'd12: ay_dac_lut = 8'd126; //  49.27%
                4'd13: ay_dac_lut = 8'd162; //  63.54%
                4'd14: ay_dac_lut = 8'd205; //  80.55%
                4'd15: ay_dac_lut = 8'd255; // 100.00%
            endcase
        end
    endfunction

    function [7:0] ym_dac_lut;
        input [4:0] lvl;
        begin
            case (lvl)
                5'd0:  ym_dac_lut = 8'h00;
                5'd1:  ym_dac_lut = 8'h01;
                5'd2:  ym_dac_lut = 8'h01;
                5'd3:  ym_dac_lut = 8'h02;
                5'd4:  ym_dac_lut = 8'h02;
                5'd5:  ym_dac_lut = 8'h03;
                5'd6:  ym_dac_lut = 8'h03;
                5'd7:  ym_dac_lut = 8'h04;
                5'd8:  ym_dac_lut = 8'h06;
                5'd9:  ym_dac_lut = 8'h07;
                5'd10: ym_dac_lut = 8'h09;
                5'd11: ym_dac_lut = 8'h0A;
                5'd12: ym_dac_lut = 8'h0C;
                5'd13: ym_dac_lut = 8'h0E;
                5'd14: ym_dac_lut = 8'h11;
                5'd15: ym_dac_lut = 8'h13;
                5'd16: ym_dac_lut = 8'h17;
                5'd17: ym_dac_lut = 8'h1B;
                5'd18: ym_dac_lut = 8'h20;
                5'd19: ym_dac_lut = 8'h25;
                5'd20: ym_dac_lut = 8'h2C;
                5'd21: ym_dac_lut = 8'h35;
                5'd22: ym_dac_lut = 8'h3E;
                5'd23: ym_dac_lut = 8'h47;
                5'd24: ym_dac_lut = 8'h54;
                5'd25: ym_dac_lut = 8'h66;
                5'd26: ym_dac_lut = 8'h77;
                5'd27: ym_dac_lut = 8'h88;
                5'd28: ym_dac_lut = 8'hA1;
                5'd29: ym_dac_lut = 8'hC0;
                5'd30: ym_dac_lut = 8'hE0;
                5'd31: ym_dac_lut = 8'hFF;
            endcase
        end
    endfunction

    assign ch_a_dac = ym_mode ? ym_dac_lut(ch_a_5b) : ay_dac_lut(ch_a_raw);
    assign ch_b_dac = ym_mode ? ym_dac_lut(ch_b_5b) : ay_dac_lut(ch_b_raw);
    assign ch_c_dac = ym_mode ? ym_dac_lut(ch_c_5b) : ay_dac_lut(ch_c_raw);

endmodule
