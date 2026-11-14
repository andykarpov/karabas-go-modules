`timescale 1ns / 1ps

/*
 tb_kg_l2_osd_icons.v

 The activity icons of kg_l2_osd_overlay in a column at the right edge (ICON_COLUMN 1, ICON_SCALE 2,
 ICON_MARGIN 4, ICON_BOX 0, ICON_COLOR): over a 200 x 100 picture, OSD off. Checked: nothing
 before any activity, an active icon in its own colour, the video around its pixels (no box),
 the other icon (not active) not shown, the slot of the second icon 20 icon pixels lower, the icon
 gone after the hold. A few seconds. Prints "tb_kg_l2_osd_icons: 0 errors".
*/

module tb_kg_l2_osd_icons;

reg clk = 1'b0;
always #5 clk = ~clk;

// 200 x 100 visible of 240 x 110
reg [8:0] hc = 0, vc = 0;
always @(posedge clk) begin
	if (hc == 9'd239) begin
		hc <= 0;
		vc <= (vc == 9'd109) ? 9'd0 : vc + 1'b1;
	end
	else
		hc <= hc + 1'b1;
end
wire de = hc < 9'd200 && vc < 9'd100;
wire hs = hc >= 9'd210 && hc < 9'd220;
wire vs = vc >= 9'd102 && vc < 9'd104;
wire [23:0] vid = de ? { hc[7:0], vc[7:0], 8'h80 } : 24'd0;
function [23:0] v_at(input integer x, input integer y);
	v_at = { x[7:0], y[7:0], 8'h80 };
endfunction

reg [7:0] icon_act = 8'd0;
wire [23:0] rgb_o;
wire hs_o, vs_o, de_o;
kg_l2_osd_overlay #(.ICONS_N(2), .ICON_SET(32'h00000030), .STRETCH_BITS(4), .ICON_HOLD(2),
	.ICON_COLUMN(1), .ICON_SCALE(2), .ICON_MARGIN(4), .ICON_BOX(0), .ICON_COLOR(24'h00C000)) u_ov(
	.wclk(clk), .osd_wr(1'b0), .osd_waddr(12'd0), .osd_wdata(8'd0), .osd_en(1'b0),
	.osd_fg(24'd0), .osd_bg(24'd0), .osd_alpha(2'd0), .osd_px(5'd0), .osd_py(4'd0),
	.osd_pw(6'd0), .osd_ph(5'd0), .osd_place(2'd0), .osd_zoom(1'b0),
	.icon_on(8'd0), .icon_act(icon_act),
	.clk(clk), .rgb_i(vid), .hs_i(hs), .vs_i(vs), .de_i(de),
	.rgb_o(rgb_o), .hs_o(hs_o), .vs_o(vs_o), .de_o(de_o)
);

// the screen as it comes out (2 clocks later than its pixel)
reg [8:0] hc1 = 0, hc2 = 0, vc1 = 0, vc2 = 0;
reg [23:0] scr [0:100*200-1];
always @(posedge clk) begin
	hc1 <= hc; hc2 <= hc1; vc1 <= vc; vc2 <= vc1;
	if (hc2 < 200 && vc2 < 100) scr[vc2 * 200 + hc2] <= rgb_o;
end

integer errors = 0;
task check(input [8*40-1:0] what, input [23:0] got, input [23:0] want);
	if (got !== want) begin
		$display("ERROR %0s: %h, want %h", what, got, want);
		errors = errors + 1;
	end
endtask
task frames(input integer n);
	integer i;
	for (i = 0; i < n; i = i + 1) begin
		@(posedge vs);
		@(negedge vs);
	end
endtask

// the column: x 200 - 32 - 4 = 164; icon 0 (the floppy, row 1 = FFF8) at y 4, icon 1 (the hard
// disk, row 1 = 3FFC) at y 4 + 40 = 44
initial begin
	frames(3);
	check("no icon", scr[46 * 200 + 168], v_at(168, 46));
	@(posedge clk); icon_act[1] = 1'b1;
	@(posedge clk); icon_act[1] = 1'b0;
	frames(2);
	check("icon 1 pixel", scr[46 * 200 + 168], 24'h00C000);
	check("icon 1 pixel, scale 2", scr[47 * 200 + 169], 24'h00C000);
	check("no box: left of its pixels", scr[46 * 200 + 164], v_at(164, 46));
	check("no box: its row 0", scr[44 * 200 + 168], v_at(168, 44));
	check("right of the column", scr[46 * 200 + 197], v_at(197, 46));
	check("icon 0 not active", scr[6 * 200 + 164], v_at(164, 6));
	@(posedge clk); icon_act[0] = 1'b1;
	@(posedge clk); icon_act[0] = 1'b0;
	frames(2);
	check("icon 0 pixel", scr[6 * 200 + 164], 24'h00C000);
	frames(6);
	check("icon 1 gone", scr[46 * 200 + 168], v_at(168, 46));
	check("icon 0 gone", scr[6 * 200 + 164], v_at(164, 6));
	$display("tb_kg_l2_osd_icons: %0d errors", errors);
	$finish;
end

endmodule
