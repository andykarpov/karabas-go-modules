`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_l2_img.v

 Target 03 IMG of MCU link v2 (karabas-go-firmware docs/link_v2.md 5.4), on the byte bus of
 kg_l2_link: the file mounter as the sector interface of img_sdc (sdc_*, the one of MiSTle /
 NanoMig that the drives of the cores use), so a core moves from img_sdc to this module without
 a change of its drives. Slot n is sdc index n.

   01 MOUNT     slot, size (8, LE), flags: sdc_img_mounted[slot] one clock with sdc_img_size
                (0 = eject); img_wp[slot] = flags bit 0; flags bit 1 / 2 (a physical drive DS0 /
                DS1 of a Go): img_phys_wr one clock, img_phys = { slot, 1 / 2 }
   02 EVENT     Z, kind, slot, argument (4, LE): the event waiting (irq while one waits), taken
                by the read: 1 read request (LBA), 2 write request (LBA), 5 DSKCHG (drive 1 / 2)
   03 RDATA     slot, 512 bytes, sum (2, LE), Z, status: the sector of a read request; status 0
                taken, 1 refused (a bad sum, a lost byte, no read request of that slot)
   04 WDATA     slot, Z, 512 bytes, sum (2): the sector of a write request
   05 DONE      slot, status: 1 done, 2 error (the request is sent again), 3 write protected
   06 FLUSH     slot: img_flush[slot] one clock (backup RAM: write the dirty sectors now)
   07 FDD_CHNG  drive, value: fdd_chng_wr one clock, fdd_chng = { drive, value } (the answer to
                fdd_chng_req: 1 changed / no disk, 0 disk in, 2 no line)

 Events of the backup RAM (kg_bk_ram with LINK 2): bk_mount (one clock, bk_slot / bk_size in
 sectors / bk_kind) raises EVENT kind 4 (slot, size (4, LE), kind): the mcu creates or opens the
 file and MOUNTs it in that slot; bk_flushed (one clock, bk_slot / bk_result 1 done, 2 a write
 failed) raises kind 3 (slot, result), the answer to a FLUSH. Each waits until it is read (one of
 a kind at a time), DSKCHG first, then the mount, the flush answer, a request.

 The requests (as img_sdc): one at a time, the lowest index first; sdc_busy goes up when one is
 taken and down with the sdc_done pulse at its end, sdc_slot is its index, sdc_error comes with
 sdc_done when it failed.
 - read: the event, then RDATA into a buffer here, checked by count and sum; the sector goes to
   the requester (sdc_byte_in_strobe / addr / data) only after DONE 1 of a taken RDATA. A read
   that fails RETRIES times more gives 512 zero bytes with sdc_error;
 - write: the sector is first copied from sdc_byte_out_data (OUT_LATENCY clocks after
   sdc_byte_addr) into the buffer (the floppy of NanoMig refills its sector buffer at once),
   then the event; WDATA reads the buffer; DONE ends it (2: again, 3: protected, an error);
 - no read of the event or no DONE in TIMEOUT: the event is raised again (RETRIES times), then
   the request fails.
 fdd_chng_req (one clock, fdd_chng_ds the drive) raises a DSKCHG event before a request event.
*/

module kg_l2_img #(
	parameter OUT_LATENCY = 3,       // clocks from sdc_byte_addr to sdc_byte_out_data
	parameter TIMEOUT = 24'd5600000, // ~200 ms at 28 MHz
	parameter RETRIES = 2'd3
) (
	input wire clk,
	input wire reset,

	input wire sel,
	input wire start,
	input wire stb,
	input wire [7:0] cmd,
	input wire [9:0] n,
	input wire [7:0] d,
	input wire rq,
	input wire [9:0] rq_m,
	output reg [7:0] q,
	output wire irq,

	output reg [7:0] sdc_img_mounted = 8'd0,
	output reg [63:0] sdc_img_size = 64'd0,
	input wire [7:0] sdc_rd,
	input wire [7:0] sdc_wr,
	input wire [31:0] sdc_sector,
	output reg sdc_busy = 1'b0,
	output reg sdc_done = 1'b0,
	output reg sdc_error = 1'b0,
	output wire [2:0] sdc_slot,
	output reg sdc_byte_in_strobe = 1'b0,
	output reg [8:0] sdc_byte_addr = 9'd0,
	output reg [7:0] sdc_byte_in_data = 8'd0,
	input wire [7:0] sdc_byte_out_data,

	output reg [7:0] img_wp = 8'd0,
	output reg img_phys_wr = 1'b0,
	output reg [15:0] img_phys = 16'd0,
	output reg [7:0] img_flush = 8'd0,
	output reg fdd_chng_wr = 1'b0,
	output reg [15:0] fdd_chng = 16'd0,
	input wire fdd_chng_req,
	input wire [1:0] fdd_chng_ds,

	input wire bk_mount,
	input wire bk_flushed,
	input wire [2:0] bk_slot,
	input wire [31:0] bk_size,
	input wire [7:0] bk_kind,
	input wire [7:0] bk_result,

	output wire active
);

localparam S_IDLE = 4'd0;
localparam S_CADDR = 4'd1;  // write: copy the sector of the requester, address out
localparam S_CDATA = 4'd2;  // write: copy, wait for the data and store it
localparam S_EV = 4'd3;     // the event waits for the mcu
localparam S_WAIT = 4'd4;   // the event is read: RDATA / WDATA, DONE
localparam S_OADDR = 4'd5;  // read: the checked sector to the requester, buffer address out
localparam S_ODATA = 4'd6;  // read: wait for the buffer, pass the byte on
localparam S_FILL = 4'd7;   // read failed: 512 zero bytes to the requester

reg [3:0] state = S_IDLE;
reg [2:0] slot = 3'd0;
reg write = 1'b0;
reg [31:0] lba = 32'd0;
reg [9:0] wpos = 10'd0;
reg [1:0] wlat = 2'd0;
reg [23:0] timeout = 24'd0;
reg [1:0] tries = 2'd0;
reg [15:0] rd_sum = 16'd0;
reg [9:0] rd_cnt = 10'd0;
reg [7:0] rd_sum_lo = 8'd0;
reg rd_ok = 1'b0;            // a RDATA of this request was taken
reg [15:0] wr_sum = 16'd0;

reg dsk_pend = 1'b0;
reg [1:0] dsk_drive = 2'd0;

// the events of the backup RAM: a mount request, a flush answer
reg bk_pend = 1'b0, fl_pend = 1'b0;
reg [2:0] bk_slot_r = 3'd0, fl_slot_r = 3'd0;
reg [31:0] bk_size_r = 32'd0;
reg [7:0] bk_kind_r = 8'd0, fl_res_r = 8'd0;

// the event taken by the read of byte 1 of EVENT; bytes 2.. come from here
reg [2:0] ev_slot = 3'd0;
reg [31:0] ev_arg = 32'd0;
reg [7:0] ev_ext = 8'd0;     // byte 7: the file kind of a mount

reg [63:0] size = 64'd0;
reg [2:0] m_slot = 3'd0;     // the slot of a MOUNT / RDATA / WDATA / DONE packet
reg [7:0] m_drive = 8'd0;    // the drive of FDD_CHNG

// the sector buffer (block ram, one write port, a synchronous read)
reg [7:0] wbuf [0:511];
reg [8:0] wbuf_ra = 9'd0;
reg [7:0] wbuf_q = 8'd0;
reg wbuf_we = 1'b0;
reg [8:0] wbuf_wa = 9'd0;
reg [7:0] wbuf_wd = 8'd0;
always @(posedge clk) begin
	wbuf_q <= wbuf[wbuf_ra];
	if (wbuf_we)
		wbuf[wbuf_wa] <= wbuf_wd;
end

assign sdc_slot = slot;
assign active = sdc_busy;
assign irq = dsk_pend || bk_pend || fl_pend || state == S_EV;

wire [7:0] req = sdc_rd | sdc_wr;
wire [2:0] req_slot = req[0] ? 3'd0 : req[1] ? 3'd1 : req[2] ? 3'd2 : req[3] ? 3'd3 :
                      req[4] ? 3'd4 : req[5] ? 3'd5 : req[6] ? 3'd6 : 3'd7;

// the event as byte 1 of EVENT reads it
wire [7:0] kind_now = dsk_pend ? 8'd5 : bk_pend ? 8'd4 : fl_pend ? 8'd3 :
                      (state == S_EV) ? (write ? 8'd2 : 8'd1) : 8'd0;
wire ev_read = sel && rq && cmd == 8'h02 && rq_m == 10'd1;

// RDATA: the status answers the sum high byte that arrives in this clock (payload 514)
wire rd_take = sel && rq && cmd == 8'h03 && rq_m == 10'd516;
wire rd_good = state == S_WAIT && !write && m_slot == slot && rd_cnt == 10'd512 &&
               rd_sum == { d, rd_sum_lo };

// WDATA: payload 2..513 the buffer (wbuf_q holds the byte at wbuf_ra), 514 / 515 the sum
wire wd_cmd = sel && cmd == 8'h04;

always @(*) begin
	q = 8'h00;
	if (sel)
		case (cmd)
			8'h02:
				case (rq_m)
					10'd1: q = kind_now;
					10'd2: q = { 5'd0, ev_slot };
					10'd3: q = ev_arg[7:0];
					10'd4: q = ev_arg[15:8];
					10'd5: q = ev_arg[23:16];
					10'd6: q = ev_arg[31:24];
					10'd7: q = ev_ext;
					default: ;
				endcase
			8'h03:
				if (rq_m == 10'd516)
					q = rd_good ? 8'd0 : 8'd1;
			8'h04:
				if (rq_m >= 10'd2 && rq_m <= 10'd513)
					q = wbuf_q;
				else if (rq_m == 10'd514)
					q = wr_sum[7:0];
				else if (rq_m == 10'd515)
					q = wr_sum[15:8];
			default: ;
		endcase
end

// a retry of the request (the event again), or its end when the retries are spent
task retry_or_fail;
	begin
		if (tries == RETRIES) begin
			if (write) begin
				sdc_busy <= 1'b0;
				sdc_done <= 1'b1;
				sdc_error <= 1'b1;
				state <= S_IDLE;
			end
			else begin
				wpos <= 10'd0;
				state <= S_FILL;
			end
		end
		else begin
			tries <= tries + 2'd1;
			timeout <= TIMEOUT;
			state <= S_EV;
		end
	end
endtask

always @(posedge clk) begin
	sdc_img_mounted <= 8'd0;
	img_phys_wr <= 1'b0;
	img_flush <= 8'd0;
	fdd_chng_wr <= 1'b0;
	sdc_done <= 1'b0;
	sdc_byte_in_strobe <= 1'b0;
	wbuf_we <= 1'b0;

	if (timeout != 0)
		timeout <= timeout - 24'd1;

	if (fdd_chng_req) begin
		dsk_pend <= 1'b1;
		dsk_drive <= fdd_chng_ds;
	end
	if (bk_mount) begin
		bk_pend <= 1'b1;
		bk_slot_r <= bk_slot;
		bk_size_r <= bk_size;
		bk_kind_r <= bk_kind;
	end
	if (bk_flushed) begin
		fl_pend <= 1'b1;
		fl_slot_r <= bk_slot;
		fl_res_r <= bk_result;
	end

	// ---- the packets ----
	if (sel && start && cmd == 8'h04)
		wbuf_ra <= 9'd0; // WDATA: the first byte is ready long before payload 2
	if (wd_cmd && rq && rq_m >= 10'd2 && rq_m <= 10'd512)
		wbuf_ra <= rq_m[8:0] - 9'd1; // the next byte, 8 sck before it is needed

	if (ev_read) begin
		ev_ext <= 8'd0;
		if (dsk_pend) begin
			dsk_pend <= 1'b0;
			ev_slot <= 3'd0;
			ev_arg <= { 30'd0, dsk_drive };
		end
		else if (bk_pend) begin
			bk_pend <= 1'b0;
			ev_slot <= bk_slot_r;
			ev_arg <= bk_size_r;
			ev_ext <= bk_kind_r;
		end
		else if (fl_pend) begin
			fl_pend <= 1'b0;
			ev_slot <= fl_slot_r;
			ev_arg <= { 24'd0, fl_res_r };
		end
		else if (state == S_EV) begin
			ev_slot <= slot;
			ev_arg <= lba;
			timeout <= TIMEOUT;
			rd_ok <= 1'b0;
			state <= S_WAIT;
		end
	end

	if (sel && stb)
		case (cmd)
			8'h01:
				case (n)
					10'd0: m_slot <= d[2:0];
					10'd1: size[7:0] <= d;
					10'd2: size[15:8] <= d;
					10'd3: size[23:16] <= d;
					10'd4: size[31:24] <= d;
					10'd5: size[39:32] <= d;
					10'd6: size[47:40] <= d;
					10'd7: size[55:48] <= d;
					10'd8: size[63:56] <= d;
					10'd9: begin
						sdc_img_mounted[m_slot] <= 1'b1;
						sdc_img_size <= size;
						img_wp[m_slot] <= d[0];
						if (d[2:1] != 2'd0) begin
							img_phys_wr <= 1'b1;
							img_phys <= { 5'd0, m_slot, 6'd0, d[2] ? 2'd2 : 2'd1 };
						end
					end
					default: ;
				endcase
			8'h03:
				if (n == 10'd0) begin
					m_slot <= d[2:0];
					rd_cnt <= 10'd0;
					rd_sum <= 16'd0;
				end
				else if (n <= 10'd512) begin
					// the bytes go into the buffer only for the read that waits for them
					if (state == S_WAIT && !write && m_slot == slot) begin
						wbuf_we <= 1'b1;
						wbuf_wa <= n[8:0] - 9'd1;
						wbuf_wd <= d;
					end
					rd_sum <= rd_sum + { 8'd0, d };
					rd_cnt <= rd_cnt + 10'd1;
				end
				else if (n == 10'd513)
					rd_sum_lo <= d;
			8'h05:
				if (n == 10'd0)
					m_slot <= d[2:0];
				else if (n == 10'd1 && state == S_WAIT && m_slot == slot) begin
					if (!write && d == 8'd1 && rd_ok) begin
						wpos <= 10'd0;
						state <= S_OADDR;
					end
					else if (write && (d == 8'd1 || d == 8'd3)) begin
						sdc_busy <= 1'b0;
						sdc_done <= 1'b1;
						sdc_error <= d != 8'd1;
						state <= S_IDLE;
					end
					else
						retry_or_fail;
				end
			8'h06:
				if (n == 10'd0)
					img_flush[d[2:0]] <= 1'b1;
			8'h07:
				if (n == 10'd0)
					m_drive <= d;
				else if (n == 10'd1) begin
					fdd_chng_wr <= 1'b1;
					fdd_chng <= { m_drive, d };
				end
			default: ;
		endcase

	if (rd_take && rd_good)
		rd_ok <= 1'b1;

	// ---- the requests ----
	if (reset) begin
		state <= S_IDLE;
		sdc_busy <= 1'b0;
		dsk_pend <= 1'b0;
		bk_pend <= 1'b0;
		fl_pend <= 1'b0;
	end
	else case (state)
		S_IDLE:
			if (req != 8'd0) begin
				slot <= req_slot;
				write <= sdc_wr[req_slot];
				lba <= sdc_sector;
				sdc_busy <= 1'b1;
				wpos <= 10'd0;
				wr_sum <= 16'd0;
				tries <= 2'd0;
				timeout <= TIMEOUT;
				state <= sdc_wr[req_slot] ? S_CADDR : S_EV;
			end

		S_CADDR:
			if (wpos == 10'd512) begin
				timeout <= TIMEOUT;
				state <= S_EV;
			end
			else begin
				sdc_byte_addr <= wpos[8:0];
				wlat <= OUT_LATENCY - 1;
				state <= S_CDATA;
			end

		S_CDATA:
			if (wlat != 0)
				wlat <= wlat - 2'd1;
			else begin
				wbuf_we <= 1'b1;
				wbuf_wa <= wpos[8:0];
				wbuf_wd <= sdc_byte_out_data;
				wr_sum <= wr_sum + { 8'd0, sdc_byte_out_data };
				wpos <= wpos + 10'd1;
				state <= S_CADDR;
			end

		S_EV:
			// the mcu reads the event (above); none in time (a firmware without IMG): again
			if (timeout == 24'd1)
				retry_or_fail;

		S_WAIT:
			if (timeout == 24'd1)
				retry_or_fail;

		S_OADDR:
			if (wpos == 10'd512) begin
				sdc_busy <= 1'b0;
				sdc_done <= 1'b1;
				sdc_error <= 1'b0;
				state <= S_IDLE;
			end
			else begin
				wbuf_ra <= wpos[8:0];
				wlat <= 2'd1; // wbuf_q one clock after wbuf_ra
				state <= S_ODATA;
			end

		S_ODATA:
			if (wlat != 0)
				wlat <= wlat - 2'd1;
			else begin
				sdc_byte_addr <= wpos[8:0];
				sdc_byte_in_data <= wbuf_q;
				sdc_byte_in_strobe <= 1'b1;
				wpos <= wpos + 10'd1;
				state <= S_OADDR;
			end

		S_FILL:
			if (wpos == 10'd512) begin
				sdc_busy <= 1'b0;
				sdc_done <= 1'b1;
				sdc_error <= 1'b1;
				state <= S_IDLE;
			end
			else begin
				sdc_byte_addr <= wpos[8:0];
				sdc_byte_in_data <= 8'h00;
				sdc_byte_in_strobe <= 1'b1;
				wpos <= wpos + 10'd1;
			end

		default: state <= S_IDLE;
	endcase
end

endmodule
