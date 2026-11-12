`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_load.v

 Target 04 LOAD of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.5), on the byte bus of
 kg_l2_link: the ROMs of the core file, the file loader and the FL items into the memory of the
 core, one bus for all of them.

   01 START   kind, slot, size (8 bytes, LE), extension: ld_start one clock after the size,
              ld_active = 1 (ld_kind, ld_slot, ld_size held until the next START)
   02 DATA    kind, address (4, LE), 1..512 bytes: ld_wr one clock per byte, ld_addr / ld_data
   03 END     kind: ld_active = 0, ld_end one clock
   04 STATUS  Z, free: 1 while ld_ready (the core can take a DATA packet of 512 bytes), else 0;
              the mcu asks before each DATA packet when the core has caps bit LOAD_READY

 kind: 0 ROM (the core holds its cpu while ld_active), 1 file loader, 2 FL item (ioctl).
 A byte comes every 250 ns at most (32 MHz sck): a core that writes slower puts a fifo behind
 ld_wr and drops ld_ready while it fills.
*/

module kg_l2_load (
	input wire clk,

	input wire sel,
	input wire stb,
	input wire [7:0] cmd,
	input wire [9:0] n,
	input wire [7:0] d,
	/* verilator lint_off UNUSEDSIGNAL */
	input wire rq,
	/* verilator lint_on UNUSEDSIGNAL */
	input wire [9:0] rq_m,
	output reg [7:0] q,

	output reg [1:0] ld_kind = 2'd0,
	output reg [7:0] ld_slot = 8'd0,
	output reg [31:0] ld_size = 32'd0,
	output reg ld_start = 1'b0,
	output reg ld_active = 1'b0,
	output reg ld_end = 1'b0,
	output reg [31:0] ld_addr = 32'd0,
	output reg [7:0] ld_data = 8'd0,
	output reg ld_wr = 1'b0,
	input wire ld_ready
);

reg [31:0] addr = 32'd0;
reg [31:0] size = 32'd0;
reg [1:0] dkind = 2'd0;

always @(*) begin
	q = 8'h00;
	if (sel && cmd == 8'h04 && rq_m == 10'd1)
		q = { 7'd0, ld_ready };
end

always @(posedge clk) begin
	ld_start <= 1'b0;
	ld_end <= 1'b0;
	ld_wr <= 1'b0;

	if (sel && stb)
		case (cmd)
			8'h01:
				case (n)
					10'd0: ld_kind <= d[1:0];
					10'd1: ld_slot <= d;
					10'd2: size[7:0] <= d;
					10'd3: size[15:8] <= d;
					10'd4: size[23:16] <= d;
					10'd5: size[31:24] <= d;
					10'd9: begin // bytes 6..8: sizes over 4 GB are not for the cores
						ld_size <= size;
						ld_start <= 1'b1;
						ld_active <= 1'b1;
					end
					default: ;
				endcase
			8'h02:
				case (n)
					10'd0: dkind <= d[1:0];
					10'd1: addr[7:0] <= d;
					10'd2: addr[15:8] <= d;
					10'd3: addr[23:16] <= d;
					10'd4: addr[31:24] <= d;
					default: begin
						// a DATA packet of another kind than the open START is dropped
						if (dkind == ld_kind && ld_active) begin
							ld_addr <= addr;
							ld_data <= d;
							ld_wr <= 1'b1;
						end
						addr <= addr + 1'b1;
					end
				endcase
			8'h03:
				if (n == 10'd0 && d[1:0] == ld_kind && ld_active) begin
					ld_active <= 1'b0;
					ld_end <= 1'b1;
				end
			default: ;
		endcase
end

endmodule
