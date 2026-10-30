`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_mcu_loader.v

 The loaders of the MCU link (a decoder on the frame and burst bus of kg_mcu_link): the mcu
 writes ROMs and files into the memory of the core, byte by byte with an address.

 ROM loader (all cores):
   ROMLOADER x d   rom_active = d[0] (the core holds its cpu while it is 1)
   ROMBANK n d     address byte n+1 (bits 15..8, 23..16, 31..24)
   ROMDATA a d     the byte d at address {bank, a}; also as burst type ROMDATA
   rom_wr: one clock when rom_addr changes while rom_active (a byte at the same address again is
   not written). While rom_active is 0 the address is followed, so turning it on writes nothing.

 File loader, with FILE_CMDS 0 the ioctl commands of the FL osd items:
   IOCTL_SLOT x s  file_reset one clock (a new file), file_slot = s (the slot of its FL item)
   IOCTL_SIZE n d  file_size byte n (0..3)
   IOCTL_STATE x d file_active = d[0]
   IOCTL_BANK n d, IOCTL_DATA a d (and bursts): as ROMBANK / ROMDATA
 with FILE_CMDS 1 the file commands (alf, nes):
   FILELOADER x d  file_reset = d[0], file_active = d[1] (levels)
   FILEBANK n d, FILEDATA a d (and bursts): as ROMBANK / ROMDATA
 file_wr: FILE_WR_EACH 1: one clock for each byte while file_active (a file starts again at 0,
 which an address compare could miss); 0: one clock when file_addr changes (rk86, spec256, alf).
 FILE_TO_ROM 1: the file bytes go out on the rom_* signals (rom_addr = file offset; nanomig),
 file_addr / file_data / file_wr are not used then.
*/

module kg_mcu_loader #(
	parameter ENABLE_FILE = 1,
	parameter FILE_CMDS = 0,     // 0: IOCTL_* (50-55), 1: FILE* (0C-0E)
	parameter FILE_WR_EACH = 1,
	parameter FILE_TO_ROM = 1
) (
	input wire clk,
	input wire rx_stb,
	input wire [7:0] rx_cmd,
	input wire [7:0] rx_addr,
	input wire [7:0] rx_data,
	input wire bst_wr,
	input wire [7:0] bst_type,
	input wire [31:0] bst_addr,
	input wire [7:0] bst_data,

	output reg rom_active = 1'b0,
	output reg [31:0] rom_addr = 32'hFFFFFFFF,
	output reg [7:0] rom_data = 8'd0,
	output reg rom_wr = 1'b0,

	output reg file_reset = 1'b0,
	output reg file_active = 1'b0,
	output wire [31:0] file_size,
	output reg [31:0] file_addr = 32'hFFFFFFFF,
	output reg [7:0] file_data = 8'd0,
	output reg file_wr = 1'b0,
	output reg [7:0] file_slot = 8'd0
);

`include "kg_mcu_cmds.vh"

localparam [7:0] F_BANK = FILE_CMDS ? CMD_FILEBANK : CMD_IOCTL_BANK;
localparam [7:0] F_DATA = FILE_CMDS ? CMD_FILEDATA : CMD_IOCTL_DATA;

wire f_bank = ENABLE_FILE && rx_cmd == F_BANK;
wire f_data = ENABLE_FILE && rx_cmd == F_DATA;
wire f_burst = ENABLE_FILE && bst_type == F_DATA;

// one register per byte: see kg_mcu_hid
reg [7:0] rom_bank1 = 8'd0, rom_bank2 = 8'd0, rom_bank3 = 8'd0;
reg [7:0] file_bank1 = 8'd0, file_bank2 = 8'd0, file_bank3 = 8'd0;
reg [7:0] size0 = 8'hFF, size1 = 8'hFF, size2 = 8'hFF, size3 = 8'hFF;
wire [31:8] rom_bank = { rom_bank3, rom_bank2, rom_bank1 };
wire [31:8] file_bank = { file_bank3, file_bank2, file_bank1 };
assign file_size = { size3, size2, size1, size0 };
reg file_byte = 1'b0;   // a file byte, FILE_WR_EACH
reg [31:0] prev_rom = 32'hFFFFFFFF, prev_file = 32'hFFFFFFFF;

always @(posedge clk) begin
	file_byte <= 1'b0;
	if (FILE_CMDS == 0)
		file_reset <= 1'b0;

	if (rx_stb) begin
		// bank and data of the rom, and of the file when it goes to the rom signals
		if (rx_cmd == CMD_ROMBANK || (FILE_TO_ROM && f_bank))
			case (rx_addr)
				8'h00: rom_bank1 <= rx_data;
				8'h01: rom_bank2 <= rx_data;
				8'h02: rom_bank3 <= rx_data;
				default: ;
			endcase
		if (rx_cmd == CMD_ROMDATA || (FILE_TO_ROM && f_data)) begin
			rom_addr <= { rom_bank, rx_addr };
			rom_data <= rx_data;
		end
		if (!FILE_TO_ROM && f_bank)
			case (rx_addr)
				8'h00: file_bank1 <= rx_data;
				8'h01: file_bank2 <= rx_data;
				8'h02: file_bank3 <= rx_data;
				default: ;
			endcase
		if (!FILE_TO_ROM && f_data) begin
			file_addr <= { file_bank, rx_addr };
			file_data <= rx_data;
		end
		if (f_data)
			file_byte <= file_active;

		if (rx_cmd == CMD_ROMLOADER)
			rom_active <= rx_data[0];
		if (ENABLE_FILE && FILE_CMDS == 0)
			case (rx_cmd)
				CMD_IOCTL_SLOT: begin
					file_reset <= 1'b1;
					file_slot <= rx_data;
				end
				CMD_IOCTL_STATE: file_active <= rx_data[0];
				CMD_IOCTL_SIZE:
					case (rx_addr)
						8'h00: size0 <= rx_data;
						8'h01: size1 <= rx_data;
						8'h02: size2 <= rx_data;
						8'h03: size3 <= rx_data;
						default: ;
					endcase
				default: ;
			endcase
		if (ENABLE_FILE && FILE_CMDS == 1 && rx_cmd == CMD_FILELOADER) begin
			file_reset <= rx_data[0];
			file_active <= rx_data[1];
		end
	end

	// bursts: the same signals as bank + data (after the frames: a burst byte wins)
	if (bst_wr) begin
		if (bst_type == CMD_ROMDATA || (FILE_TO_ROM && f_burst)) begin
			rom_addr <= bst_addr;
			rom_data <= bst_data;
		end
		if (!FILE_TO_ROM && f_burst) begin
			file_addr <= bst_addr;
			file_data <= bst_data;
		end
		if (f_burst)
			file_byte <= file_active;
	end
end

// the write strobes, a clock after the address
always @(posedge clk) begin
	rom_wr <= FILE_TO_ROM && FILE_WR_EACH && file_byte;
	if (!rom_active)
		prev_rom <= rom_addr;
	else if (prev_rom != rom_addr) begin
		rom_wr <= 1'b1;
		prev_rom <= rom_addr;
	end

	file_wr <= 1'b0;
	if (ENABLE_FILE && !FILE_TO_ROM) begin
		if (FILE_WR_EACH)
			file_wr <= file_byte;
		else if (prev_file != file_addr) begin
			file_wr <= 1'b1;
			prev_file <= file_addr;
		end
	end
end

endmodule
