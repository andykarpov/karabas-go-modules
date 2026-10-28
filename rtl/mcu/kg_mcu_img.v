`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_mcu_img.v

 The file mounter of the MCU link (karabas-go-firmware docs/protocol.md, IMG_* commands; a
 decoder on the frame and burst bus of kg_mcu_link, one transmit port). kg_img_sdc / img_sdc.v
 turns it into a sector interface.
   IMG_SLOT x s       the slot of the next size
   IMG_SIZE n d       size byte n; byte 7 sets img_size, img_mounted[slot] one clock
   IMG_PHYS s d       img_phys = s d, img_phys_wr one clock (a slot on a physical drive)
   IMG_LBA 0/1 d      img_sum: the 16-bit sum of the sector read, before its result
   IMG_SEC x r        img_result = r (1 done, 2 error), img_result_wr one clock
   IMG_BUF_BANK x b   bit 0: the half of the sector of the next data
   IMG_BUF_DATA a d   (or a burst of that type) a byte of the sector read: img_data_wr one
                      clock with img_data_addr, img_data
   IMG_FLUSH s 00     img_flush[s] one clock: write the dirty sectors of slot s now (kg_bk_ram)
 Frames to the mcu (requests, write data): img_q_di held with img_q_wr until img_q_ack (one
 clock); a word goes out when the queue has room and not in the clock after an ack (the sender
 is putting up its next word then).
*/

module kg_mcu_img (
	input wire clk,
	input wire rx_stb,
	input wire [7:0] rx_cmd,
	input wire [7:0] rx_addr,
	input wire [7:0] rx_data,
	input wire bst_wr,
	input wire [7:0] bst_type,
	/* verilator lint_off UNUSEDSIGNAL */
	input wire [31:0] bst_addr,    // [8:0]
	/* verilator lint_on UNUSEDSIGNAL */
	input wire [7:0] bst_data,

	output reg [7:0] img_mounted = 8'd0,
	output reg [63:0] img_size = 64'd0,
	output reg img_data_wr = 1'b0,
	output reg [8:0] img_data_addr = 9'd0,
	output reg [7:0] img_data = 8'd0,
	output reg img_result_wr = 1'b0,
	output reg [7:0] img_result = 8'd0,
	output wire [15:0] img_sum,
	output reg img_phys_wr = 1'b0,
	output reg [15:0] img_phys = 16'd0,
	output reg [7:0] img_flush = 8'd0,

	input wire img_q_wr,
	input wire [23:0] img_q_di,
	output reg img_q_ack = 1'b0,

	output wire tx_req,
	output wire [23:0] tx_data,
	input wire tx_grant,
	input wire tx_full
);

`include "kg_mcu_cmds.vh"

reg [2:0] slot = 3'd0;
reg bank = 1'b0;
// one register per byte: see kg_mcu_hid
reg [7:0] size0 = 8'd0, size1 = 8'd0, size2 = 8'd0, size3 = 8'd0, size4 = 8'd0, size5 = 8'd0, size6 = 8'd0;
reg [7:0] sum_lo = 8'd0, sum_hi = 8'd0;
assign img_sum = { sum_hi, sum_lo };

integer i;
always @(posedge clk) begin
	img_mounted <= 8'd0;
	img_phys_wr <= 1'b0;
	img_data_wr <= 1'b0;
	img_result_wr <= 1'b0;
	img_flush <= 8'd0;
	if (rx_stb)
		case (rx_cmd)
			CMD_IMG_SLOT: slot <= rx_data[2:0];
			CMD_IMG_SIZE:
				case (rx_addr)
					8'h00: size0 <= rx_data;
					8'h01: size1 <= rx_data;
					8'h02: size2 <= rx_data;
					8'h03: size3 <= rx_data;
					8'h04: size4 <= rx_data;
					8'h05: size5 <= rx_data;
					8'h06: size6 <= rx_data;
					8'h07: begin
						img_size <= { rx_data, size6, size5, size4, size3, size2, size1, size0 };
						for (i = 0; i < 8; i = i + 1)
							if (slot == i[2:0])
								img_mounted[i] <= 1'b1;
					end
					default: ;
				endcase
			CMD_IMG_PHYS: begin
				img_phys <= { rx_addr, rx_data };
				img_phys_wr <= 1'b1;
			end
			CMD_IMG_LBA:
				case (rx_addr)
					8'h00: sum_lo <= rx_data;
					8'h01: sum_hi <= rx_data;
					default: ;
				endcase
			CMD_IMG_SEC: begin
				img_result <= rx_data;
				img_result_wr <= 1'b1;
			end
			CMD_IMG_BUF_BANK: bank <= rx_data[0];
			CMD_IMG_FLUSH:
				if (rx_data == 8'h00)
					for (i = 0; i < 8; i = i + 1)
						if (rx_addr[2:0] == i[2:0])
							img_flush[i] <= 1'b1;
			CMD_IMG_BUF_DATA: begin
				img_data_addr <= { bank, rx_addr };
				img_data <= rx_data;
				img_data_wr <= 1'b1;
			end
			default: ;
		endcase
	if (bst_wr && bst_type == CMD_IMG_BUF_DATA) begin
		img_data_addr <= bst_addr[8:0];
		img_data <= bst_data;
		img_data_wr <= 1'b1;
	end

	img_q_ack <= tx_grant;
end

assign tx_req = img_q_wr && !img_q_ack && !tx_full;
assign tx_data = img_q_di;

endmodule
