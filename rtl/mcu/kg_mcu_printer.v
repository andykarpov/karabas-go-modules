`timescale 1ns / 1ps
`default_nettype wire

/*
 kg_mcu_printer.v
 The USB printer of the mcu (karabas-go-firmware docs/usb_printer.md, protocol.md "USB printer"):
 a decoder on the frame bus of kg_mcu_link and one transmit port.
 - prn_wr (a one-clock strobe) sends prn_data as CMD_PRINTER_DATA 00 d, then a status request
   (CMD_PRINTER_STATUS 00 00); busy stays high from prn_wr until the answer CMD_PRINTER_STATUS 00 ss
   (ss bit 7: busy) comes, so a byte is never sent before the mcu has taken the one before.
 - busy is high until the first status (the firmware: BUSY = 1 at the start); a status request
   is sent at the start (it also enables the status updates of the mcu) and again after RETRY_CLKS
   without an answer while one is awaited. The mcu sends its status on changes and every 100 ms.
*/

module kg_mcu_printer #(
	parameter RETRY_CLKS = 24'd5000000      // 100 ms at 50 MHz
) (
	input wire clk,
	input wire rx_stb,
	input wire [7:0] rx_cmd,
	input wire [7:0] rx_addr,
	input wire [7:0] rx_data,

	input wire [7:0] prn_data,
	input wire prn_wr,
	output wire prn_busy,

	output wire tx_req,
	output wire [23:0] tx_data,
	input wire tx_grant,
	input wire tx_full
);

`include "kg_mcu_cmds.vh"

reg [7:0] data = 8'd0;
reg data_pend = 1'b0;
reg query_pend = 1'b1;              // the first request at the start
reg waiting = 1'b1;                 // a status is awaited
reg known = 1'b0;                   // a status came
reg status_busy = 1'b1;
reg [23:0] timer = 24'd0;

assign tx_req = (data_pend || query_pend) && !tx_full;
assign tx_data = data_pend ? {CMD_PRINTER_DATA, 8'h00, data} : {CMD_PRINTER_STATUS, 8'h00, 8'h00};
assign prn_busy = !known || status_busy || waiting || data_pend;

always @(posedge clk) begin
	if (prn_wr) begin
		data <= prn_data;
		data_pend <= 1'b1;
		waiting <= 1'b1;
	end
	if (tx_grant) begin
		if (data_pend) begin
			data_pend <= 1'b0;
			query_pend <= 1'b1;
		end else
			query_pend <= 1'b0;
		timer <= 24'd0;
	end
	if (rx_stb && rx_cmd == CMD_PRINTER_STATUS && rx_addr == 8'h00) begin
		status_busy <= rx_data[7];
		known <= 1'b1;
		waiting <= 1'b0;
	end
	// no answer: ask again
	if (waiting && !query_pend && !data_pend && !tx_grant) begin
		if (timer == RETRY_CLKS) begin
			timer <= 24'd0;
			query_pend <= 1'b1;
		end else
			timer <= timer + 1'd1;
	end
end

endmodule
