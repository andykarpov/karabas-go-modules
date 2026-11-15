`timescale 1ns / 1ps
/*
 tb_hdmi_tx_outreg: hdmi_tx (zhdmi_tx.vhd) with OUTPUT_REG = 0 and 1 (two ghdl --synth netlists, the
 second with its modules renamed *_r1) on the same video and audio: a frame of 160 x 40 pixels with
 blanking, random pixels, audio samples at 48 kHz; DVI (audio_en = 0) for the first frame, then HDMI
 with its data islands. The serial outputs (ODDR2 / OBUFDS models below) are taken on both edges of the
 serial clock: every data channel of OUTPUT_REG = 1 must be the one of OUTPUT_REG = 0 one pixel (10 bits)
 later, the clock channel the same.
*/
module tb_hdmi_tx_outreg;

reg clk = 1'b0, sclk = 1'b0;
always #2 sclk = ~sclk;                 // 5 x the pixel clock (20 ns)
initial forever begin #1; clk = 1'b1; #10; clk = 1'b0; #9; end   // rises 1 ns after a sclk edge
wire sclk_n = ~sclk;
reg reset = 1'b1;

reg [23:0] rgb = 24'd0;
reg vs = 1'b0, hs = 1'b0, de = 1'b0;
reg audio_en = 1'b0;
reg [23:0] al = 24'd0, ar = 24'd0;
reg audio_clk = 1'b0;

wire c0n, c0p, c1n, c1p;
wire [2:0] d0n, d0p, d1n, d1p;
hdmi_tx    u0 (.clk(clk), .sclk(sclk), .sclk_n(sclk_n), .reset(reset), .rgb(rgb), .vsync(vs), .hsync(hs),
	.de(de), .audio_en(audio_en), .audio_l(al), .audio_r(ar), .audio_clk(audio_clk),
	.tx_clk_n(c0n), .tx_clk_p(c0p), .tx_d_n(d0n), .tx_d_p(d0p));
hdmi_tx_r1 u1 (.clk(clk), .sclk(sclk), .sclk_n(sclk_n), .reset(reset), .rgb(rgb), .vsync(vs), .hsync(hs),
	.de(de), .audio_en(audio_en), .audio_l(al), .audio_r(ar), .audio_clk(audio_clk),
	.tx_clk_n(c1n), .tx_clk_p(c1p), .tx_d_n(d1n), .tx_d_p(d1p));

// the video: 160 x 40, de 128 x 32, hsync and vsync in the blanking; inputs change at the falling clk
integer x = 0, y = 0, frame = 0, seed = 5, acnt = 0;
always @(negedge clk) if (!reset) begin
	x = x + 1;
	if (x == 160) begin
		x = 0; y = y + 1;
		if (y == 40) begin y = 0; frame = frame + 1; end
	end
	de <= (x < 128) && (y < 32);
	hs <= (x >= 136) && (x < 148);
	vs <= (y >= 34) && (y < 36);
	rgb <= $random(seed);
	acnt = acnt + 1;
	if (acnt >= 520) begin           // 48 kHz at a 25 MHz pixel clock
		acnt = 0;
		audio_clk <= 1'b1;
		al <= $random(seed); ar <= $random(seed);
	end else
		audio_clk <= 1'b0;
end

// audio_en from a register of the pixel clock, as kg_hdmi_ft gives it (audio_en_s): it selects the
// words of the DVI or the HDMI encoders combinationally, so a change between the edges would show a
// word for half a pixel that only OUTPUT_REG = 1 takes
always @(posedge clk) audio_en <= (frame >= 1);

// the serial bits on both edges; u1 against u0 ten bits before
reg [3:0] h [0:15];                     // the history of u0: {clk, d2, d1, d0}
integer n = 0, i, errors = 0, checked = 0, ones = 0;
task take;
	begin
		for (i = 15; i > 0; i = i - 1) h[i] = h[i - 1];
		h[0] = {c0p, d0p};
		n = n + 1;
		if (n > 400 && !reset) begin
			checked = checked + 1;
			if (d0p != 3'b000) ones = ones + 1;
			if ({c1p, d1p} !== {h[0][3], h[10][2:0]}) begin
				errors = errors + 1;
				if (errors <= 10)
					$display("tb_hdmi_tx_outreg: bit %0d: clk %b data %b, expected clk %b data %b (frame %0d)",
						n, c1p, d1p, h[0][3], h[10][2:0], frame);
			end
		end
	end
endtask
always @(posedge sclk) #1.5 take;
always @(negedge sclk) #1.5 take;

initial begin
	for (i = 0; i < 16; i = i + 1) h[i] = 4'd0;
	#203 reset = 1'b0;
	wait (frame == 3);
	if (ones == 0) begin errors = errors + 1; $display("tb_hdmi_tx_outreg: the data channels never changed"); end
	$display("tb_hdmi_tx_outreg: %0d serial bits compared", checked);
	$display("tb_hdmi_tx_outreg: %0d errors", errors);
	$finish;
end

endmodule

// the Xilinx primitives of tmds_serializer
module ODDR2 #(parameter DDR_ALIGNMENT = 0, parameter INIT = 1'b0, parameter SRTYPE = 0) (
	input wire C0, input wire C1, input wire CE, input wire D0, input wire D1, input wire R, input wire S,
	output reg Q
);
initial Q = INIT;
always @(posedge C0) Q <= D0;
always @(posedge C1) Q <= D1;
endmodule

module OBUFDS #(parameter CAPACITANCE = 0, parameter IOSTANDARD = 0, parameter SLEW = 0) (
	input wire I, output wire O, output wire OB
);
assign O = I;
assign OB = ~I;
endmodule
