`timescale 1ns / 1ps

/*
 tb_mem.v: the kg_* memories against the coregen blk_mem_gen / dist_mem_gen cores they replace
 (behavioural models from the ipcore_dir of the sibling cores), random stimulus on one clock,
 outputs compared every clock. Run by run_ipcore_eq.sh.
*/
module tb_mem;
reg clk = 0;
always #5 clk = ~clk;
integer errors = 0, checks = 0, i;

reg en, enb, we, we2;
reg [3:0] bwa, bwb;
reg [17:0] a, b;
reg [31:0] d, d2;

// ram2k (nes): SP 2Kx8, ena, write first
wire [7:0] sp_c, sp_k;
ram2k c_sp (.clka(clk), .ena(en), .wea(we), .addra(a[10:0]), .dina(d[7:0]), .douta(sp_c));
kg_spram #(.DW(8), .AW(11)) k_sp (.clk(clk), .en(en), .we(we), .addr(a[10:0]), .din(d[7:0]), .dout(sp_k));

// ram8k (nes): SP 8Kx8, ena, write first
wire [7:0] sp8_c, sp8_k;
ram8k c_sp8 (.clka(clk), .ena(en), .wea(we), .addra(a[12:0]), .dina(d[7:0]), .douta(sp8_c));
kg_spram #(.DW(8), .AW(13)) k_sp8 (.clk(clk), .en(en), .we(we), .addr(a[12:0]), .din(d[7:0]), .dout(sp8_k));

// framebuffer (nes): SDP 64Kx6
wire [5:0] fb_c, fb_k;
framebuffer c_fb (.clka(clk), .wea(we), .addra(a[15:0]), .dina(d[5:0]), .clkb(clk), .addrb(b[15:0]), .doutb(fb_c));
kg_sdpram #(.DW(6), .AW(16)) k_fb (.clka(clk), .wea(we), .addra(a[15:0]), .dina(d[5:0]), .clkb(clk), .enb(1'b1), .addrb(b[15:0]), .doutb(fb_k));

// rom_font (nes): SDP 2Kx8, the osd font as init (rom_font.mif / rom_font.hex)
wire [7:0] of_c, of_k;
rom_font c_of (.clka(clk), .wea(we), .addra(a[10:0]), .dina(d[7:0]), .clkb(clk), .addrb(b[10:0]), .doutb(of_c));
kg_sdpram #(.DW(8), .AW(11), .INIT_FILE("rom_font.hex")) k_of (.clka(clk), .wea(we), .addra(a[10:0]), .dina(d[7:0]),
	.clkb(clk), .enb(1'b1), .addrb(b[10:0]), .doutb(of_k));

// osd_vram (alf): SDP 1Kx16
wire [15:0] sdp_c, sdp_k;
osd_vram c_sdp (.clka(clk), .wea(we), .addra(a[9:0]), .dina(d[15:0]), .clkb(clk), .addrb(b[9:0]), .doutb(sdp_c));
kg_sdpram #(.DW(16), .AW(10)) k_sdp (.clka(clk), .wea(we), .addra(a[9:0]), .dina(d[15:0]), .clkb(clk), .enb(1'b1), .addrb(b[9:0]), .doutb(sdp_k));

// sectorbuf (pdp2026): TDP 256x16
wire [15:0] tda_c, tdb_c, tda_k, tdb_k;
sectorbuf c_tdp (.clka(clk), .wea(we), .addra(a[7:0]), .dina(d[15:0]), .douta(tda_c),
	.clkb(clk), .web(we2), .addrb(b[7:0]), .dinb(d2[15:0]), .doutb(tdb_c));
kg_tdpram #(.DW(16), .AW(8)) k_tdp (.clka(clk), .ena(1'b1), .wea(we), .addra(a[7:0]), .dina(d[15:0]), .douta(tda_k),
	.clkb(clk), .enb(1'b1), .web(we2), .addrb(b[7:0]), .dinb(d2[15:0]), .doutb(tdb_k));

// cache (next186): TDP 4Kx32 with ena / enb
wire [31:0] ca_c, cb_c, ca_k, cb_k;
cache c_cache (.clka(clk), .ena(en), .wea(bwa), .addra(a[11:0]), .dina(d), .douta(ca_c),
	.clkb(clk), .enb(enb), .web(bwb), .addrb(b[11:0]), .dinb(d2), .doutb(cb_c));
kg_tdpram #(.DW(32), .AW(12), .WE_W(4)) k_cache (.clka(clk), .ena(en), .wea(bwa), .addra(a[11:0]), .dina(d), .douta(ca_k),
	.clkb(clk), .enb(enb), .web(bwb), .addrb(b[11:0]), .dinb(d2), .doutb(cb_k));

// font (rk86): ROM 1Kx8 with init
wire [7:0] rom_c, rom_k;
font c_rom (.clka(clk), .addra(a[9:0]), .douta(rom_c));
kg_sprom #(.DW(8), .AW(10), .INIT_FILE("font.hex")) k_rom (.clk(clk), .en(1'b1), .addr(a[9:0]), .dout(rom_k));

// keyjoy_sdpram_64_6 (next): distributed SDP 64x6 with init
wire [5:0] kj_c, kj_k;
keyjoy_sdpram_64_6 c_kj (.clk(clk), .we(we), .a(a[5:0]), .d(d[5:0]), .dpra(b[5:0]), .dpo(kj_c));
kg_dist_sdpram #(.DW(6), .AW(6), .INIT_FILE("keyjoy.hex")) k_kj (.clk(clk), .we(we), .a(a[5:0]), .d(d[5:0]), .spo(), .dpra(b[5:0]), .dpo(kj_k));

// spram_320_9 (next): distributed SP 320x9
wire [8:0] dsp_c, dsp_k;
spram_320_9 c_dsp (.clk(clk), .we(we), .a(a[8:0]), .d(d[8:0]), .spo(dsp_c));
kg_dist_spram #(.DW(9), .AW(9), .DEPTH(320)) k_dsp (.clk(clk), .we(we), .a(a[8:0]), .d(d[8:0]), .spo(dsp_k));

// sdpram_128_8, sdpram_16_9, sdpram_64_9 (next): distributed SDP, no init
wire [7:0] s128_c, s128_k;
wire [8:0] s16_c, s16_k, s64_c, s64_k;
sdpram_128_8 c_s128 (.clk(clk), .we(we), .a(a[6:0]), .d(d[7:0]), .dpra(b[6:0]), .dpo(s128_c));
kg_dist_sdpram #(.DW(8), .AW(7)) k_s128 (.clk(clk), .we(we), .a(a[6:0]), .d(d[7:0]), .spo(), .dpra(b[6:0]), .dpo(s128_k));
sdpram_16_9 c_s16 (.clk(clk), .we(we), .a(a[3:0]), .d(d[8:0]), .dpra(b[3:0]), .dpo(s16_c));
kg_dist_sdpram #(.DW(9), .AW(4)) k_s16 (.clk(clk), .we(we), .a(a[3:0]), .d(d[8:0]), .spo(), .dpra(b[3:0]), .dpo(s16_k));
sdpram_64_9 c_s64 (.clk(clk), .we(we), .a(a[5:0]), .d(d[8:0]), .dpra(b[5:0]), .dpo(s64_c));
kg_dist_sdpram #(.DW(9), .AW(6)) k_s64 (.clk(clk), .we(we), .a(a[5:0]), .d(d[8:0]), .spo(), .dpra(b[5:0]), .dpo(s64_k));

// sdpbram_16k_8 (next sprite patterns): block SDP 16Kx8 with enb, default data E3
wire [7:0] pat_c, pat_k;
sdpbram_16k_8 c_pat (.clka(clk), .wea(we), .addra(a[13:0]), .dina(d[7:0]), .clkb(clk), .enb(enb), .addrb(b[13:0]), .doutb(pat_c));
kg_sdpram #(.DW(8), .AW(14), .INIT_FILE("e3.hex")) k_pat (.clka(clk), .wea(we), .addra(a[13:0]), .dina(d[7:0]),
	.clkb(clk), .enb(enb), .addrb(b[13:0]), .doutb(pat_k));

task check;
	input [255:0] name;
	input [31:0] c, k;
	begin
		checks = checks + 1;
		if (c !== k) begin
			errors = errors + 1;
			if (errors < 20) $display("%t %0s: coregen %h kg %h", $time, name, c, k);
		end
	end
endtask

initial begin
	en = 0; enb = 0; we = 0; we2 = 0; bwa = 0; bwb = 0; a = 0; b = 0; d = 0; d2 = 0;
	// let the coregen models load their init files
	repeat (4) @(posedge clk);
	// first pass reads the init contents only
	for (i = 0; i < 64; i = i + 1) begin
		@(negedge clk); a = i; b = 63 - i + (i[0] ? 16000 : 0); en = 1; enb = 1;
		@(negedge clk); check("rom", rom_c, rom_k); check("keyjoy", kj_c, kj_k); check("pattern init", pat_c, pat_k);
		check("rom_font init", of_c, of_k);
	end
	for (i = 0; i < 40000; i = i + 1) begin
		@(negedge clk);
		// compare the outputs of the last edge (and the asynchronous reads of the last addresses)
		if (i > 0) begin
			check("ram2k", sp_c, sp_k);
			check("osd_vram", sdp_c, sdp_k);
			check("ram8k", sp8_c, sp8_k);
			check("framebuffer", fb_c, fb_k);
			check("rom_font", of_c, of_k);
			check("sectorbuf a", tda_c, tda_k); check("sectorbuf b", tdb_c, tdb_k);
			check("cache a", ca_c, ca_k); check("cache b", cb_c, cb_k);
			check("font", rom_c, rom_k);
			check("keyjoy", kj_c, kj_k);
			if (a[8:0] < 320) check("spram_320_9", dsp_c, dsp_k);
			check("sdpbram_16k_8", pat_c, pat_k);
		end
		en = ($random & 7) != 0; enb = ($random & 7) != 0;
		we = ($random & 3) == 0; we2 = ($random & 3) == 0;
		// a narrow address range, so words written are read back soon
		a = {$random} % 24; b = {$random} % 24;
		if (i[0]) begin a = a + 300; b = b + 300; end
		d = $random; d2 = $random;
		bwa = we ? $random : 4'h0; bwb = we2 ? $random : 4'h0;
		// same address on both ports with a write is undefined in the primitive: avoid it
		if (a == b && (we || we2)) b = b ^ 18'h1;
		@(posedge clk); #1;
		if (a[8:0] < 320) check("spram_320_9 async", dsp_c, dsp_k);
		check("keyjoy async", kj_c, kj_k);
		check("sdpram_128_8 async", s128_c, s128_k);
		check("sdpram_16_9 async", s16_c, s16_k);
		check("sdpram_64_9 async", s64_c, s64_k);
	end
	$display("tb_mem: %0d checks, %0d errors", checks, errors);
	$finish;
end
endmodule
