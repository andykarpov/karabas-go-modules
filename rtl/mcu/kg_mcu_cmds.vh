// Command codes of the MCU link: the first byte of a frame (cmd, addr, data) and the type byte of
// a burst. Must match karabas-go-firmware src/config.h (docs/protocol.md). Included inside the
// kg_mcu_* modules (localparams, once per module; each module uses some of them).
/* verilator lint_off UNUSEDPARAM */

// mcu -> fpga
localparam [7:0] CMD_KBD          = 8'h01;
localparam [7:0] CMD_MOUSE        = 8'h02;
localparam [7:0] CMD_JOY          = 8'h03;
localparam [7:0] CMD_BTNS         = 8'h04;
localparam [7:0] CMD_SWITCHES     = 8'h05;
localparam [7:0] CMD_ROMBANK      = 8'h06;
localparam [7:0] CMD_ROMDATA      = 8'h07;
localparam [7:0] CMD_ROMLOADER    = 8'h08;
localparam [7:0] CMD_CONTROL      = 8'h09; // firmware: CMD_SPI_CONTROL; tsconf and others: CMD_FT
localparam [7:0] CMD_PS2_SCANCODE = 8'h0B;
localparam [7:0] CMD_FILEBANK     = 8'h0C;
localparam [7:0] CMD_FILEDATA     = 8'h0D;
localparam [7:0] CMD_FILELOADER   = 8'h0E;
localparam [7:0] CMD_MIDI         = 8'h16; // a MIDI byte of a USB keyboard, to cores with caps bit 4 (kg_mcu_midi)
localparam [7:0] CMD_OSD          = 8'h20;
localparam [7:0] CMD_IMG_SLOT     = 8'h40;
localparam [7:0] CMD_IMG_SIZE     = 8'h41;
localparam [7:0] CMD_IMG_LBA      = 8'h42; // both directions
localparam [7:0] CMD_IMG_SEC      = 8'h43; // both directions
localparam [7:0] CMD_IMG_BUF_BANK = 8'h44; // both directions
localparam [7:0] CMD_IMG_BUF_DATA = 8'h45; // both directions
localparam [7:0] CMD_IMG_PHYS     = 8'h46;
localparam [7:0] CMD_IMG_FLUSH    = 8'h47; // both directions (kg_bk_ram)
localparam [7:0] CMD_IOCTL_SLOT   = 8'h50;
localparam [7:0] CMD_IOCTL_SIZE   = 8'h51;
localparam [7:0] CMD_IOCTL_BANK   = 8'h52;
localparam [7:0] CMD_IOCTL_DATA   = 8'h53;
localparam [7:0] CMD_IOCTL_EXT    = 8'h54;
localparam [7:0] CMD_IOCTL_STATE  = 8'h55;
localparam [7:0] CMD_CAPS         = 8'hF7; // both directions
localparam [7:0] CMD_ESP_UART     = 8'hF8; // both directions
localparam [7:0] CMD_HW_SETUP     = 8'hF9;
localparam [7:0] CMD_RTC          = 8'hFA; // both directions
localparam [7:0] CMD_FLASHBOOT    = 8'hFB; // fpga -> mcu: load the core in data[4:0] (next)
localparam [7:0] CMD_UART         = 8'hFC; // both directions
localparam [7:0] CMD_INIT_START   = 8'hFD;
localparam [7:0] CMD_INIT_DONE    = 8'hFE;
localparam [7:0] CMD_NOPE         = 8'hFF; // both directions

// fpga -> mcu
localparam [7:0] CMD_DEBUG_ADDR    = 8'h30;
localparam [7:0] CMD_DEBUG_DATA    = 8'h31;
localparam [7:0] CMD_BK_MOUNT      = 8'h48; // kg_bk_ram
localparam [7:0] CMD_AUDIO_PEAKS_L = 8'h70;
localparam [7:0] CMD_AUDIO_PEAKS_R = 8'h71;
/* verilator lint_on UNUSEDPARAM */
