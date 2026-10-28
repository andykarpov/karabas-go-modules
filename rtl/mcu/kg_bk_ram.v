`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_bk_ram.v

 Backup RAM of a cartridge (the battery RAM of the NES, and the like) kept in a file on the sd card
 through the file mounter of the MCU link (karabas-go-firmware docs/protocol.md, "Backup RAM"):
 the core says how big its backup RAM is, the firmware opens or creates the file (.sav next to the
 game) and mounts it in an img slot, this module reads it into the memory of the core and writes
 the sectors the core changed back to it.

 - start (one clock) with size (sectors of 512 bytes, 1..64; 0 = the game has no backup RAM) and
   kind (0 = .sav): CMD_BK_MOUNT to the mcu: 48 00..03 size (LE), 48 10 SLOT, 48 80 kind;
 - the mcu mounts the file in SLOT (IMG_SLOT / IMG_SIZE, size 0 first): its sectors (at most size,
   a shorter file only its own) are read through img_sdc and copied to the memory port; busy holds
   from start until the memory has them (the core keeps its CPU in reset). No mount in
   MOUNT_CLOCKS (a firmware without the command), or a size 0 without a size after it in
   GRACE_CLOCKS (no file: no sd card, read only): busy ends, mounted stays 0, nothing is written;
 - wr with wr_addr (a byte offset in the backup RAM, written by the core) marks its sector dirty;
 - autosave: the dirty sectors are copied from the memory port and written to the file when the
   writes have stopped for IDLE_CLOCKS, or MAX_CLOCKS after a sector got dirty (games that write
   their backup RAM all the time); a write into a sector being saved marks it dirty again;
 - CMD_IMG_FLUSH SLOT 00 of the mcu (img_flush[SLOT], before it loads another game or core): the
   dirty sectors are written at once, then the answer 47 SLOT 01 (done) or 02 (a write failed);
   answered at once when nothing is mounted;
 - the memory port: mem_req held with mem_we, mem_addr, mem_din until mem_ack (one clock; mem_dout
   is valid with it), mem_req drops or changes at that edge (the aux port of the NES memory
   controller). The sectors go through a sector buffer here (a block RAM): img_sdc passes and takes
   the bytes at a fixed rate, the memory port has its own;
 - the reply frames of img_sdc and of this module share img_q (this module owns the queue of
   kg_mcu: a core with other img_sdc requesters puts their slots on another queue).
 kg_mcu needs ENABLE_IMG 1 and ENABLE_BK 1 (caps bit 3: the firmware asks for flushes then).
*/

module kg_bk_ram #(
	parameter [2:0] SLOT = 3'd0,
	parameter IDLE_CLOCKS = 27'd28000000,  // ~1 s at 28 MHz: autosave after the last write
	parameter MAX_CLOCKS = 27'd112000000,  // ~4 s: autosave after the first write at the latest
	parameter MOUNT_CLOCKS = 27'd28000000, // ~1 s: no mount after CMD_BK_MOUNT, go on without a file
	parameter GRACE_CLOCKS = 27'd280000,   // ~10 ms: a size 0 mount without a size after it, no file
	parameter TIMEOUT = 24'd5600000,       // img_sdc: ~200 ms for an answer of the mcu
	parameter RETRIES = 2'd3               // img_sdc
) (
	input wire clk,
	input wire reset,               // a new game: back to no backup RAM (flush before it)

	input wire start,
	input wire [6:0] size,
	input wire [7:0] kind,
	output wire busy,
	output reg mounted = 1'b0,      // a file is mounted: its sectors are in the memory, writes saved
	output wire saving,             // a sector is being written (a led, the osd)
	output reg save_error = 1'b0,   // a sector write failed (until reset)

	input wire wr,
	/* verilator lint_off UNUSEDSIGNAL */
	input wire [14:0] wr_addr,      // [14:9], the sector
	/* verilator lint_on UNUSEDSIGNAL */

	output reg mem_req = 1'b0,
	output reg mem_we = 1'b0,
	output reg [14:0] mem_addr = 15'd0,
	output reg [7:0] mem_din = 8'd0,
	input wire mem_ack,
	input wire [7:0] mem_dout,

	// kg_mcu (ENABLE_IMG, ENABLE_BK)
	input wire [7:0] img_mounted,
	input wire [63:0] img_size,
	input wire img_data_wr,
	input wire [8:0] img_data_addr,
	input wire [7:0] img_data,
	input wire img_result_wr,
	input wire [7:0] img_result,
	input wire [15:0] img_sum,
	input wire [7:0] img_flush,
	output wire img_q_wr,
	output wire [23:0] img_q_di,
	input wire img_q_ack
);

localparam [7:0] CMD_IMG_FLUSH = 8'h47;
localparam [7:0] CMD_BK_MOUNT = 8'h48;

localparam S_RUN = 4'd0;    // the game runs: autosave, flush
localparam S_MOUNT = 4'd1;  // queue CMD_BK_MOUNT
localparam S_MWAIT = 4'd2;  // wait for the mount
localparam S_LREQ = 4'd3;   // load: request the sector
localparam S_LWAIT = 4'd4;  // load: its bytes into the buffer
localparam S_LCOPY = 4'd5;  // load: buffer to the memory
localparam S_SCOPY = 4'd6;  // save: memory to the buffer
localparam S_SREQ = 4'd7;   // save: request the write
localparam S_SWAIT = 4'd8;  // save: img_sdc takes the buffer and writes it
localparam S_FANS = 4'd9;   // queue the flush answer

reg [3:0] state = S_RUN;
reg [6:0] bk_size = 7'd0;       // sectors of the backup RAM
reg [6:0] load_n = 7'd0;        // sectors to load (the file can be shorter)
reg [5:0] sec = 6'd0;
reg [9:0] pos = 10'd0;
reg [1:0] step = 2'd0;
reg [2:0] m = 3'd0;             // CMD_BK_MOUNT frame
reg [26:0] timer = 27'd0;       // MWAIT: mount / grace
reg grace = 1'b0;
reg [26:0] idle = 27'd0;
reg [26:0] age = 27'd0;
reg [63:0] dirty = 64'd0;
reg flush_pend = 1'b0, flush_err = 1'b0;
reg rd_req = 1'b0, wr_req = 1'b0;

// own reply frames (CMD_BK_MOUNT, the flush answer); img_sdc is idle while they go out
reg own_wr = 1'b0;
reg [23:0] own_di = 24'd0;
wire sdc_q_wr;
wire [23:0] sdc_q_di;
assign img_q_wr = own_wr || sdc_q_wr;
assign img_q_di = own_wr ? own_di : sdc_q_di;
wire own_ack = img_q_ack && own_wr;
wire own_free = !own_wr || own_ack;

// ---------------- img_sdc ----------------

wire [7:0] sdc_img_mounted;
wire [63:0] sdc_img_size;
wire sdc_busy, sdc_done, sdc_error, sdc_byte_in_strobe;
wire [8:0] sdc_byte_addr;
wire [7:0] sdc_byte_in_data, sbuf_q;

img_sdc #(.OUT_LATENCY(2), .TIMEOUT(TIMEOUT), .RETRIES(RETRIES)) u_sdc(
	.clk(clk), .reset(reset),
	.img_mounted(img_mounted), .img_size(img_size),
	.img_data_wr(img_data_wr), .img_data_addr(img_data_addr), .img_data(img_data),
	.img_result_wr(img_result_wr), .img_result(img_result), .img_sum(img_sum),
	.img_q_wr(sdc_q_wr), .img_q_di(sdc_q_di), .img_q_ack(img_q_ack && !own_wr),
	.sdc_img_mounted(sdc_img_mounted), .sdc_img_size(sdc_img_size),
	.sdc_rd({7'd0, rd_req} << SLOT), .sdc_wr({7'd0, wr_req} << SLOT), .sdc_sector({26'd0, sec}),
	.sdc_busy(sdc_busy), .sdc_done(sdc_done), .sdc_error(sdc_error), .sdc_slot(),
	.sdc_byte_in_strobe(sdc_byte_in_strobe), .sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_byte_in_data), .sdc_byte_out_data(sbuf_q),
	.active()
);

// sector buffer: written by img_sdc (load) or the memory port (save), read by the memory port
// (load) or img_sdc (save: its byte two clocks after sdc_byte_addr, OUT_LATENCY 2)
wire sbuf_we = (state == S_LWAIT && sdc_byte_in_strobe) || (state == S_SCOPY && mem_ack);
wire [8:0] sbuf_wa = state == S_LWAIT ? sdc_byte_addr : pos[8:0];
wire [7:0] sbuf_wd = state == S_LWAIT ? sdc_byte_in_data : mem_dout;
wire [8:0] sbuf_ra = state == S_LCOPY ? pos[8:0] : sdc_byte_addr;
kg_sdpram #(.DW(8), .AW(9)) sbuf(
	.clka(clk), .wea(sbuf_we), .addra(sbuf_wa), .dina(sbuf_wd),
	.clkb(clk), .enb(1'b1), .addrb(sbuf_ra), .doutb(sbuf_q));

assign busy = start || state == S_MOUNT || state == S_MWAIT || state == S_LREQ || state == S_LWAIT || state == S_LCOPY;
assign saving = state == S_SCOPY || state == S_SREQ || state == S_SWAIT;

// the lowest dirty sector
reg [5:0] first;
integer i;
always @(*) begin
	first = 6'd0;
	for (i = 63; i >= 0; i = i - 1)
		if (dirty[i])
			first = i[5:0];
end

// sectors of the mounted file, at most bk_size
wire [6:0] file_secs = (|sdc_img_size[63:15]) ? 7'd64 : {1'b0, sdc_img_size[14:9]} + {6'd0, |sdc_img_size[8:0]};

always @(posedge clk) begin
	if (own_ack)
		own_wr <= 1'b0;
	if (timer != 0)
		timer <= timer - 27'd1;
	if (idle != 0)
		idle <= idle - 27'd1;
	if (img_flush[SLOT])
		flush_pend <= 1'b1;

	if (reset) begin
		state <= S_RUN;
		mounted <= 1'b0;
		save_error <= 1'b0;
		dirty <= 64'd0;
		flush_pend <= 1'b0;
		flush_err <= 1'b0;
		rd_req <= 1'b0;
		wr_req <= 1'b0;
		mem_req <= 1'b0;
		own_wr <= 1'b0;
	end
	else begin
		case (state)
			S_RUN: begin
				if (dirty != 0 && age != MAX_CLOCKS)
					age <= age + 27'd1;
				if (start) begin
					bk_size <= size;
					mounted <= 1'b0;
					dirty <= 64'd0;
					m <= 3'd0;
					if (size != 0)
						state <= S_MOUNT;
				end
				else if (flush_pend && (dirty == 0 || flush_err || !mounted)) begin
					if (own_free) begin
						own_wr <= 1'b1;
						own_di <= { CMD_IMG_FLUSH, 5'd0, SLOT, flush_err ? 8'h02 : 8'h01 };
						state <= S_FANS;
					end
				end
				else if (mounted && dirty != 0 && (idle == 0 || age == MAX_CLOCKS || (flush_pend && !flush_err))) begin
					sec <= first;
					dirty[first] <= 1'b0;
					pos <= 10'd0;
					step <= 2'd0;
					state <= S_SCOPY;
				end
			end

			S_FANS:
				if (own_ack) begin
					flush_pend <= 1'b0;
					flush_err <= 1'b0;
					state <= S_RUN;
				end

			S_MOUNT:
				if (own_free) begin
					own_wr <= 1'b1;
					case (m)
						3'd0: own_di <= { CMD_BK_MOUNT, 8'h00, 1'b0, bk_size };
						3'd1: own_di <= { CMD_BK_MOUNT, 8'h01, 8'h00 };
						3'd2: own_di <= { CMD_BK_MOUNT, 8'h02, 8'h00 };
						3'd3: own_di <= { CMD_BK_MOUNT, 8'h03, 8'h00 };
						3'd4: own_di <= { CMD_BK_MOUNT, 8'h10, 5'd0, SLOT };
						default: own_di <= { CMD_BK_MOUNT, 8'h80, kind };
					endcase
					m <= m + 3'd1;
					if (m == 3'd5) begin
						timer <= MOUNT_CLOCKS;
						grace <= 1'b0;
						state <= S_MWAIT;
					end
				end

			S_MWAIT:
				if (sdc_img_mounted[SLOT] && sdc_img_size != 0) begin
					load_n <= file_secs < bk_size ? file_secs : bk_size;
					sec <= 6'd0;
					state <= S_LREQ;
				end
				else if (sdc_img_mounted[SLOT] && !grace) begin
					// size 0: an eject before the file, or no file
					grace <= 1'b1;
					timer <= GRACE_CLOCKS;
				end
				else if (timer == 27'd1)
					state <= S_RUN;

			S_LREQ: begin
				rd_req <= 1'b1;
				if (sdc_busy) begin
					rd_req <= 1'b0;
					state <= S_LWAIT;
				end
			end

			S_LWAIT:
				if (sdc_done) begin
					pos <= 10'd0;
					step <= 2'd0;
					state <= S_LCOPY;
				end

			S_LCOPY:
				if (pos == 10'd512) begin
					if ({1'b0, sec} + 7'd1 == load_n) begin
						mounted <= 1'b1;
						dirty <= 64'd0;
						state <= S_RUN;
					end
					else begin
						sec <= sec + 6'd1;
						state <= S_LREQ;
					end
				end
				else case (step)
					2'd0: step <= 2'd1;          // sbuf_ra = pos
					2'd1: begin                  // sbuf_q is the byte
						mem_req <= 1'b1;
						mem_we <= 1'b1;
						mem_addr <= { sec, pos[8:0] };
						mem_din <= sbuf_q;
						step <= 2'd2;
					end
					default:
						if (mem_ack) begin
							mem_req <= 1'b0;
							pos <= pos + 10'd1;
							step <= 2'd0;
						end
				endcase

			S_SCOPY:
				if (pos == 10'd512)
					state <= S_SREQ;
				else if (step == 2'd0) begin
					mem_req <= 1'b1;
					mem_we <= 1'b0;
					mem_addr <= { sec, pos[8:0] };
					step <= 2'd1;
				end
				else if (mem_ack) begin          // the byte goes into sbuf (sbuf_we)
					mem_req <= 1'b0;
					pos <= pos + 10'd1;
					step <= 2'd0;
				end

			S_SREQ: begin
				wr_req <= 1'b1;
				if (sdc_busy) begin
					wr_req <= 1'b0;
					state <= S_SWAIT;
				end
			end

			S_SWAIT:
				if (sdc_done) begin
					if (sdc_error) begin
						dirty[sec] <= 1'b1;
						save_error <= 1'b1;
						if (flush_pend)
							flush_err <= 1'b1;
					end
					state <= S_RUN;
				end

			default: state <= S_RUN;
		endcase

		// a write of the core: after the clear of a sector being saved, so it is saved again
		if (wr && mounted && {1'b0, wr_addr[14:9]} < bk_size) begin
			dirty[wr_addr[14:9]] <= 1'b1;
			idle <= IDLE_CLOCKS;
		end
		if (dirty == 0)
			age <= 27'd0;
	end
end

endmodule
