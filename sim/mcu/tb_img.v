`timescale 1ns / 1ps

// File mounter: mcu.vhd + img_sdc.v with a model of the mcu firmware (karabas-go-firmware
// storage/img_mount.cpp) on the spi link and a model of a NanoMig requester (sdc_*).
// - mount slot 0 (901120 bytes): sdc_img_mounted[0] with the size;
// - read sector 5 with classic frames, then sector 6 with a burst: the requester gets the bytes;
// - write sector 7: the mcu model gets the 512 bytes of the requester.
// Ends with "tb_img: N errors". `define KG_MCU: kg_mcu.v in place of mcu.vhd.

module tb_img;

parameter FRAME_GAP = 500; // ns between two classic frames of the mcu (CS high)

reg clk = 1'b0;
always #17.65 clk = ~clk;

// ---------------- spi link ----------------

reg cs_n = 1'b1, sck = 1'b0, mosi = 1'b0, burst_cs_n = 1'b1;
wire miso;

task spi_byte(input [7:0] tx, output [7:0] rx);
	integer k;
	begin
		for (k = 7; k >= 0; k = k - 1) begin
			mosi = tx[k];
			#31;
			sck = 1'b1;
			rx[k] = miso;
			#31;
			sck = 1'b0;
		end
	end
endtask

reg [7:0] rc, ra, rd;
task frame(input [7:0] c, input [7:0] a, input [7:0] d);
	begin
		cs_n = 1'b0;
		#100;
		spi_byte(c, rc);
		spi_byte(a, ra);
		spi_byte(d, rd);
		#50;
		cs_n = 1'b1;
		#FRAME_GAP;
		handle_reply;
	end
endtask

// ---------------- dut ----------------

wire [7:0] img_mounted, img_data, img_result;
wire [15:0] img_sum;
wire [63:0] img_size;
wire img_data_wr, img_result_wr, img_q_wr, img_q_ack;
wire [8:0] img_data_addr;
wire [23:0] img_q_di;

`ifdef KG_MCU
// kg_mcu with the nanomig configuration, its chip select filter on
kg_mcu #(.BURST_MAX_MHZ(32), .CS_FILTER(3), .ENABLE_IMG(1)) mcu(
	.UART_TX_MODE(1'b0), .UART_DLM(8'h00), .UART_DLL(8'h00), .UART_DLM_WR(1'b0), .UART_DLL_WR(1'b0),
	.DEBUG_ADDR(16'h0000), .DEBUG_DATA(16'h0000),
`else
mcu #(.BURST_MAX_MHZ(32)) mcu(
`endif
	.CLK(clk),
	.N_RESET(1'b1),
	.MCU_MOSI(mosi),
	.MCU_MISO(miso),
	.MCU_SCK(sck),
	.MCU_SS(cs_n),
	.MCU_SPI_FT_SS(1'b1),
	.MCU_SPI_SD2_SS(1'b1),
	.MCU_BURST_CS_N(burst_cs_n),
	.RTC_A(8'h00),
	.RTC_DI(8'h00),
	.RTC_CS(1'b0),
	.RTC_WR_N(1'b1),
	.UART_TX_DATA(8'h00),
	.UART_TX_WR(1'b0),
	.FT_MISO(1'b1),
	.SD2_MISO(1'b1),
	.MATRIX_CMD(24'h000000),
	.MATRIX_CMD_WR(1'b0),
	.IMG_MOUNTED(img_mounted),
	.IMG_SIZE(img_size),
	.IMG_DATA_WR(img_data_wr),
	.IMG_DATA_ADDR(img_data_addr),
	.IMG_DATA(img_data),
	.IMG_RESULT_WR(img_result_wr),
	.IMG_RESULT(img_result),
	.IMG_SUM(img_sum),
	.IMG_Q_WR(img_q_wr),
	.IMG_Q_DI(img_q_di),
	.IMG_Q_ACK(img_q_ack)
);

reg [7:0] sdc_rd = 8'd0, sdc_wr = 8'd0;
reg [31:0] sdc_sector = 32'd0;
wire [7:0] sdc_img_mounted, sdc_byte_in_data;
wire [63:0] sdc_img_size;
wire sdc_busy, sdc_done, sdc_byte_in_strobe, sdc_error;
reg done_err = 1'b0;     // sdc_error at the last sdc_done
reg [7:0] wr_result = 8'h01; // the answer of the mcu model to a write
wire [8:0] sdc_byte_addr;
reg [7:0] out_d1 = 8'd0, out_d2 = 8'd0; // the floppy: data 2 clocks after the address

img_sdc img_sdc(
	.clk(clk), .reset(1'b0),
	.img_mounted(img_mounted), .img_size(img_size),
	.img_data_wr(img_data_wr), .img_data_addr(img_data_addr), .img_data(img_data),
	.img_result_wr(img_result_wr), .img_result(img_result), .img_sum(img_sum),
	.img_q_wr(img_q_wr), .img_q_di(img_q_di), .img_q_ack(img_q_ack),
	.sdc_img_mounted(sdc_img_mounted), .sdc_img_size(sdc_img_size),
	.sdc_rd(sdc_rd), .sdc_wr(sdc_wr), .sdc_sector(sdc_sector),
	.sdc_busy(sdc_busy), .sdc_done(sdc_done), .sdc_error(sdc_error),
	.sdc_byte_in_strobe(sdc_byte_in_strobe), .sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_byte_in_data), .sdc_byte_out_data(out_d2),
	.active()
);

integer errors = 0;
integer incomplete = 0; // requests the mcu model got without all their IMG_LBA frames
integer incomplete0;

// ---------------- requester model ----------------
// as paula_floppy: the first byte 511 ends the sector, bytes after it are not taken

reg [7:0] rx_sector [0:511];
integer rx_count = 0;
reg rx_closed = 0;
always @(posedge clk) begin
	out_d1 <= sdc_byte_addr[7:0] ^ 8'h5A ^ { 7'd0, sdc_byte_addr[8] };
	out_d2 <= out_d1;
	if (sdc_byte_in_strobe) begin
		if (rx_closed) begin
			if (errors < 10) $display("ERROR: byte %0d after the end of the sector", sdc_byte_addr);
			errors = errors + 1;
		end
		else begin
			rx_sector[sdc_byte_addr] = sdc_byte_in_data;
			rx_count = rx_count + 1;
			if (sdc_byte_addr == 9'd511) rx_closed = 1;
		end
	end
	if (sdc_img_mounted != 0)
		$display("%t mounted %b size %0d", $time, sdc_img_mounted, sdc_img_size);
	if (sdc_done) begin
		$display("%t sdc_done", $time);
		done_err <= sdc_error;
	end
end

task request(input wr, input [31:0] sector);
	begin
		@(posedge clk);
		rx_closed = 0;
		sdc_sector <= sector;
		if (wr) sdc_wr <= 8'h01; else sdc_rd <= 8'h01;
		wait (sdc_busy);
		@(posedge clk);
		sdc_rd <= 8'h00;
		sdc_wr <= 8'h00;
	end
endtask

// ---------------- mcu firmware model ----------------

reg [31:0] req_lba = 0;
reg [7:0] req_slot = 0, req_op = 0;
reg req_pending = 0, req_started = 0;
reg drop_sec = 0;
reg drop_lba1 = 0;
reg trace = 0;    // lose the next IMG_LBA 1 frame of the fpga
reg drop_data = 0;    // lose one sector data frame of the next read (mcu -> fpga)
reg [3:0] lba_mask = 0;
reg [15:0] wsum_rx = 0; // lose the next IMG_SEC frame of the fpga (as seen on hardware)
reg [7:0] wr_bank = 0;
reg [7:0] wr_buf [0:511];
integer wr_count = 0;

task handle_reply;
	begin
		if (rc != 8'hFF && trace) $display("%t   frame %02x %02x %02x", $time, rc, ra, rd);
		case (rc)
			8'h42: if (drop_lba1 && ra == 1) begin drop_lba1 = 0; $display("%t mcu: IMG_LBA 1 dropped", $time); end
			       else begin
			         req_lba[ra*8 +: 8] = rd;
			         if (ra == 0) begin req_started = 1; lba_mask = 4'b0001; end
			         else lba_mask[ra[1:0]] = 1'b1;
			       end
			8'h43: if (drop_sec) begin drop_sec = 0; $display("%t mcu: IMG_SEC dropped", $time); end
			       else begin req_slot = ra; req_op = rd; req_pending = 1; req_started = 0; end
			8'h44: if (ra == 8'h10) wsum_rx[7:0] = rd; else if (ra == 8'h11) wsum_rx[15:8] = rd; else wr_bank = rd;
			8'h45: begin wr_buf[{wr_bank[0], ra}] = rd; wr_count = wr_count + 1; end
			default: ;
		endcase
	end
endtask

function [7:0] sector_byte(input [31:0] lba, input [8:0] i);
	sector_byte = lba[7:0] * 8'd17 + i[7:0] + { 7'd0, i[8] } * 8'd3;
endfunction

reg use_burst = 0;
// a short low spike on the classic chip select in the middle of a burst (as on Mini G: the top
// lets a low through at once and holds it 3 clocks)
reg cs_spike = 0, spike_go = 0;
always @(posedge spike_go) begin
	#420;        // over the last two shifting sck edges of the byte (434, 496 ns)
	cs_n = 1'b0;
	#110;
	cs_n = 1'b1;
end
reg [15:0] sum;
task serve;
	integer i, n;
	reg [7:0] dummy;
	begin
		n = 0;
		while (!req_pending && n < 200000) begin frame(8'hFF, 0, 0); n = n + 1; end
		if (!req_pending) begin $display("ERROR: no request"); errors = errors + 1; end
		req_pending = 0;
		$display("%t mcu: request slot %0d op %0d lba %0d", $time, req_slot, req_op, req_lba);
		if (lba_mask != 4'b1111) begin
			$display("%t mcu: incomplete lba, error", $time);
			incomplete = incomplete + 1;
			lba_mask = 0;
			frame(8'h43, req_slot, 8'h02);
		end
		else if (req_op == 1) begin
			lba_mask = 0;
			if (use_burst) begin
				burst_cs_n = 1'b0;
				#100;
				spi_byte(8'h45, dummy);
				spi_byte(8'h00, dummy); spi_byte(8'h00, dummy); spi_byte(8'h00, dummy); spi_byte(8'h00, dummy);
				for (i = 0; i < 512; i = i + 1) begin
					spike_go = cs_spike && (i == 300 || i == 511);
					spi_byte(sector_byte(req_lba, i), dummy);
					if (spike_go) #200; // the rp2040 pauses between bytes now and then
				end
				spike_go = 0;
				#100;
				burst_cs_n = 1'b1;
				#500;
			end
			else begin
				for (i = 0; i < 512; i = i + 1) begin
					if (i % 256 == 0) frame(8'h44, 8'h00, i / 256);
					if (drop_data && i == 100) begin drop_data = 0; $display("%t mcu: data byte dropped", $time); end
					else frame(8'h45, i % 256, sector_byte(req_lba, i));
				end
			end
			sum = 0;
			for (i = 0; i < 512; i = i + 1) sum = sum + sector_byte(req_lba, i);
			frame(8'h42, 8'h00, sum[7:0]);
			frame(8'h42, 8'h01, sum[15:8]);
			frame(8'h43, req_slot, 8'h01);
		end
		else begin
			lba_mask = 0;
			wr_count = 0;
			n = 0;
			while (wr_count < 512 && n < 4000) begin frame(8'hFF, 0, 0); n = n + 1; end
			// the sum frames come behind the data
			n = 0;
			while (n < 10) begin frame(8'hFF, 0, 0); n = n + 1; end
			sum = 0;
			for (i = 0; i < 512; i = i + 1) sum = sum + wr_buf[i];
			if (wr_count != 512 || sum != wsum_rx) begin
				$display("ERROR: write data %0d bytes, sum %04x, core sum %04x", wr_count, sum, wsum_rx);
				errors = errors + 1;
			end
			frame(8'h43, req_slot, wr_result);
		end
		// the firmware keeps polling for the next request
		n = 0;
		while (!req_pending && !req_started && n < 20) begin frame(8'hFF, 0, 0); n = n + 1; end
	end
endtask

// ---------------- test ----------------

integer i;
initial begin
	#2000;
	// mount slot 0: size 0, then 901120 (an adf)
	frame(8'h40, 8'h00, 8'h00);
	for (i = 0; i < 8; i = i + 1) frame(8'h41, i, 8'h00);
	for (i = 0; i < 8; i = i + 1) frame(8'h41, i, (64'd901120 >> (8 * i)) & 8'hFF);
	#1000;
	if (sdc_img_size != 64'd901120) begin $display("ERROR: size %0d", sdc_img_size); errors = errors + 1; end

	// read sector 5, classic frames
	rx_count = 0;
	fork request(0, 32'd5); serve; join
	wait (!sdc_busy);
	if (req_lba != 5 || req_op != 1) begin $display("ERROR: request lba %0d op %0d", req_lba, req_op); errors = errors + 1; end
	if (rx_count != 512) begin $display("ERROR: read %0d bytes", rx_count); errors = errors + 1; end
	for (i = 0; i < 512; i = i + 1)
		if (rx_sector[i] !== sector_byte(5, i)) begin
			if (errors < 10) $display("ERROR: read byte %0d %02x", i, rx_sector[i]);
			errors = errors + 1;
		end

	// read sector 6, burst
	use_burst = 1;
	rx_count = 0;
	fork request(0, 32'd6); serve; join
	wait (!sdc_busy);
	if (rx_count != 512) begin $display("ERROR: burst read %0d bytes", rx_count); errors = errors + 1; end
	for (i = 0; i < 512; i = i + 1)
		if (rx_sector[i] !== sector_byte(6, i)) begin
			if (errors < 10) $display("ERROR: burst byte %0d %02x", i, rx_sector[i]);
			errors = errors + 1;
		end

	// a lost IMG_SEC: the fpga sends the request again after its timeout
	drop_sec = 1;
	rx_count = 0;
	fork request(0, 32'd9); serve; join
	wait (!sdc_busy);
	if (req_lba != 9 || rx_count != 512) begin
		$display("ERROR: read after a lost IMG_SEC: lba %0d, %0d bytes", req_lba, rx_count);
		errors = errors + 1;
	end

	// a lost IMG_LBA byte: the mcu answers an error, the core asks again
	use_burst = 0; // the loss tests use classic frames
	drop_lba1 = 1;
	rx_count = 0;
	fork request(0, 32'h0000_0213); begin serve; serve; end join
	wait (!sdc_busy);
	if (req_lba != 32'h213 || rx_count != 512) begin $display("ERROR: lost lba byte: lba %0d, %0d bytes", req_lba, rx_count); errors = errors + 1; end
	for (i = 0; i < 512; i = i + 1)
		if (rx_sector[i] !== sector_byte(32'h213, i)) begin
			if (errors < 10) $display("ERROR: lost lba byte: byte %0d %02x", i, rx_sector[i]);
			errors = errors + 1;
		end

	// a lost data frame of a read: the core sees 511 bytes and asks again
	drop_data = 1;
	rx_count = 0;
	fork request(0, 32'd12); begin serve; serve; end join
	wait (!sdc_busy);
	if (rx_count != 512) begin $display("ERROR: lost data frame: %0d bytes", rx_count); errors = errors + 1; end
	for (i = 0; i < 512; i = i + 1)
		if (rx_sector[i] !== sector_byte(12, i)) begin
			if (errors < 10) $display("ERROR: lost data frame: byte %0d %02x", i, rx_sector[i]);
			errors = errors + 1;
		end

	// back-to-back burst reads, the next request right after sdc_done (as the floppy reads a track),
	// with spikes on the classic chip select during the bursts: every reply word the core takes
	// from its queue has to go out in a frame
	use_burst = 1;
	cs_spike = 1;
	incomplete0 = incomplete;
	for (i = 10; i < 30; i = i + 1) begin
		rx_count = 0;
		fork request(0, i); serve; join
		wait (!sdc_busy);
		if (req_lba != i || rx_count != 512) begin
			$display("ERROR: back-to-back read %0d: lba %0d, %0d bytes", i, req_lba, rx_count);
			errors = errors + 1;
		end
	end

	cs_spike = 0;
	if (incomplete != incomplete0) begin
		$display("ERROR: %0d requests lost a reply frame (cs spikes during bursts)", incomplete - incomplete0);
		errors = errors + 1;
	end

	// write sector 7: the requester's bytes are addr ^ 5A ^ addr[8]
	fork request(1, 32'd7); serve; join
	wait (!sdc_busy);
	if (req_lba != 7 || req_op != 2) begin $display("ERROR: request lba %0d op %0d", req_lba, req_op); errors = errors + 1; end
	for (i = 0; i < 512; i = i + 1)
		if (wr_buf[i] !== ((i & 8'hFF) ^ 8'h5A ^ (i >> 8))) begin
			if (errors < 10) $display("ERROR: write byte %0d %02x", i, wr_buf[i]);
			errors = errors + 1;
		end

	if (done_err) begin $display("ERROR: sdc_error after a good write"); errors = errors + 1; end

	// a write to a write protected image: the answer 3 ends it at once with sdc_error, no retry
	wr_result = 8'h03;
	fork request(1, 32'd9); serve; join
	wr_result = 8'h01;
	// it ends within clocks of the answer (a retry would wait for TIMEOUT and send it again)
	for (i = 0; i < 100 && sdc_busy; i = i + 1) @(posedge clk);
	if (sdc_busy) begin $display("ERROR: a write protected write did not end at the answer"); errors = errors + 1; end
	else if (!done_err) begin $display("ERROR: no sdc_error after a write protected write"); errors = errors + 1; end

	$display("tb_img: %0d errors", errors);
	$finish;
end

initial begin
	repeat (4) #1000000000;
	$display("ERROR: timeout");
	$display("tb_img: 1 errors");
	$finish;
end

endmodule
