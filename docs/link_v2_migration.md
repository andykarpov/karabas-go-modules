# Moving a core to MCU link v2

For the sessions that move a `karabas-go-core-*` to link v2. The protocol is
karabas-go-firmware `docs/link_v2.md` (section 11: every v1 scheme and its v2 form); the module
is `rtl/mcu/kg_mcu2.v` here. The first core moved was vic20 (Mini G, Ф2): its
`src/rtl/karabas_minig_top.v` is the simplest example.

**Status: released** (2026-11-14). Firmware v26111315 and later loads link 2 cores; every core
of the release runs v2 on all three boards (Go and Mini were moved in one pass after Mini G; most
of them never ran on a Go / Mini board yet). Examples: vic20 (the first one, Verilog), atari2600 /
sega / atarist (Go / Mini tops from `src/tools/mktops.py`), nes (`.sav` through `kg_bk_ram`),
archie / nanomig (`hdf_ata`), profi / tsconf / baseconf (VHDL tops), next (Go / Mini tops by
`src/tools/link2_tops.py` from the Mini G top).

## Before you start

- **Branches.** Link v2 is in master of every repo (firmware, modules, tools, cores); the
  `link-v2` branches are gone. Work as for any change: a feature branch from master, PR, merge.
- **What exists.** Phases of `docs/link_v2.md` section 10. Ф2: transport, SYS, HID, LOAD; Ф3:
  OSD (`kg_l2_osd`); Ф4: IMG, the file mounter (`kg_l2_img`); Ф5: PORT (`kg_l2_port`), RTC
  (`kg_l2_rtc`), AUX (`kg_l2_aux`). All targets of the spec are in, and `kg_bk_ram`
  (`.sav`, parameter `LINK(2)`) and `hdf_ata` run on the `SDC_*` side of `kg_mcu2`. Do not invent commands: a new command goes into the
  spec first, then here and into the firmware.
- **Firmware.** v26111315 or later (it speaks both links; v1 cores work on it unchanged). An
  older firmware does not load a link 2 core at all (its bitstream is in section
  `BITSTREAM_LINK2`): write "needs firmware 26111315" into the PR / release notes of a core.
- **Nothing of v1 in a v2 core.** No `kg_mcu`, `kg_mcu_*`, `kg_spi_slave`, `kg_burst_rx`,
  `kg_soft_switches`, frames, bursts. The core is edited to the new ports.

## Steps

1. **Submodule.** `cd modules && git fetch && git checkout origin/master` (commit the new
   submodule commit). Newer modules can add ports without a default (`BK_*` of `kg_mcu2`): a
   VHDL instance must name them (tie `BK_MOUNT`, `BK_FLUSHED` '0', `BK_SLOT` "000",
   `BK_SIZE` x"00000000", `BK_KIND` / `BK_RESULT` x"00" without `kg_bk_ram`).
2. **prj.** Remove `ctl/kg_soft_switches.v`, `mcu/kg_spi_slave.v`, `mcu/kg_burst_rx.v`,
   `mcu/kg_mcu_link.v`, `mcu/kg_mcu_*.v`, `mcu/kg_mcu.v`; add `mcu/kg_l2_link.v`,
   `mcu/kg_l2_sys.v`, `mcu/kg_l2_hid.v`, `mcu/kg_l2_load.v`, `mcu/kg_mcu2.v` (+ `mcu/kg_l2_osd.v`,
   `video/osd/kg_l2_osd_overlay.v`, `mcu/kg_l2_img.v` for the OSD and the file mounter).
3. **Pins.** `MCU_INT` goes out on the IO1 line: `MCU_IO[1]` on Mini / Mini G, `MCU_SPI_IO[0]`
   on Go (the index is swapped there). It is the pin of the burst ready of v1, so the ucf does
   not change for burst cores; `MCU_IO[0]` (the old burst chip select) is an input (`1'bz`).
   `MCU_SCK` stays on its global buffer as now (IBUFG + BUFG; FT812 / SD2 take the IBUFG output)
   where it is on a clock pin (Mini G); on Mini / Go it goes to `kg_mcu2` straight.
   Go: the FT812 / SD2 chip selects are `MCU_SPI_FT_CS_N` / `MCU_SPI_SD2_CS_N` (no `MCU_IO`).
   **Mini / Mini G: `FT_CLK_OUT` must always carry a clock of ~8 MHz** (an ODDR2 of a core
   clock, 7..8 MHz), the FT812 hums into the audio without it; on Mini the pin was `MCU_IO<4>`
   (E7) in old ucf files.
4. **The instance.** `kg_mcu2 #(.CAPS(..), .SW_N(n), .SW_INIT(..), .CS_FILTER(3),
   .ENABLE_FT(1), .ENABLE_SD2(1))` in the clock of the core that took `kg_mcu` (any clock from
   ~12.5 MHz works with 32 MHz sck in the testbench).
5. **The core side**, from `kg_mcu` to `kg_mcu2` (section 11 of the spec has the reasons):

   | `kg_mcu` | `kg_mcu2` | Edit |
   |---|---|---|
   | `SOFTSW_COMMAND` + `kg_soft_switches` (`regs`) | `SW` (`SW_N` x 8 bits, switch n = `SW[n*8 +: 8]`), `SW_WR` / `SW_INDEX` / `SW_VALUE` | drop `kg_soft_switches`, take `SW` where `regs` was (the field cuts stay the same) |
   | `KB_STATUS`, `KB_DAT0..5` | `KBD` = `{ key6 .. key1, modifiers }`, `KBD_WR` | `.KBD({ kb_dat5, ..., kb_dat0, kb_status })` keeps the old nets; the report changes whole |
   | `KB_SCANCODE` + `KB_SCANCODE_UPD` toggle, `XT_SCANCODE` + `XT_SCANCODE_UPD` | `PS2_CODE`, `PS2_KIND` (0 set 2, 1 XT), `PS2_WR` strobe | a toggle detector becomes `if (PS2_WR && !PS2_KIND)` |
   | `PS2_COMMAND` / `_WR` | `PS2_CMD` / `PS2_CMD_WR` | same |
   | `MS_X`, `MS_Y`, `MS_Z` (4 bits), `MS_B` (3), `MS_UPD` toggle | `MS_X`, `MS_Y`, `MS_Z` (8), `MS_B` (8), `MS_WR` strobe | `if (ms_upd != ms_upd_d)` becomes `if (MS_WR)` |
   | `JOY_L`, `JOY_R` (13 bits) | `JOY_L`, `JOY_R` (16), `JOY_WR` | take bits 12..0 |
   | `BTNS` (2) | `BTNS` (6: 0, 1 board, 2..5 LED matrix) | take bits 1..0 |
   | `HWID`, `DVI_ONLY`, `CORE_BUILD`, `FW_BUILD`, `BUSY`, `FT_*`, `SD2_*` | `HW_ID`, the rest the same | none |
   | `FLASHBOOT_START` / `_COREID` | `RELOAD_REQ` / `RELOAD_CORE` | same |
   | `ROMLOADER_ACTIVE`, `ROMLOAD_ADDR/DATA/WR` | `LD_*` with `LD_KIND == 0` | `rom_active = LD_ACTIVE && kind 0`, `rom_wr = LD_WR && kind 0`, addr / data = `LD_ADDR` / `LD_DATA` |
   | `FILELOAD_RESET/ACTIVE/ADDR/DATA/WR/SLOT/SIZE` (file loader or ioctl) | `LD_*` with `LD_KIND == 1` (file loader) or `2` (FL items) | `file_reset = LD_START && kind`, `file_active = LD_ACTIVE && kind`, `file_wr = LD_WR && kind`, `LD_SLOT`, `LD_SIZE`; `FILE_TO_ROM` / `FILE_WR_EACH` become the core's own choice (`LD_WR` is one clock per byte) |
   | `MCU_BURST_READY` (a slow memory) | `LD_READY` + `CAPS` bit 4 | drive `LD_READY` low while the core cannot take 512 bytes |
   | (CAPS) | bits 0 IMG, 5 RTC, 6 AUX come from `ENABLE_*`; set the others (2 WP images, 4 LD_READY, 9 MIDI) in `CAPS` | |
   | `IMG_*` + `img_sdc` (file mounter) | `ENABLE_IMG(1)`, `IMG_OUT_LATENCY` (= `OUT_LATENCY` of `img_sdc`): `SDC_*` (the `sdc_*` side of `img_sdc`, the same ports), `IMG_WP`, `IMG_PHYS*`, `IMG_FLUSH`, `FDD_CHNG*` (`FDD_CHNG_REQ` / `_DS` in), `IMG_ACTIVE`; `CAPS` bit 0 (bit 2: write protected images) | drop `img_sdc`: its `sdc_*` nets go to `kg_mcu2` as they are; prj adds `mcu/kg_l2_img.v` |
   | `kg_bk_ram` (`.sav`) | `kg_bk_ram #(.LINK(2))` on `SDC_*`, its events to `BK_MOUNT` / `BK_FLUSHED` / `BK_SLOT` / `BK_SIZE` / `BK_KIND` / `BK_RESULT`; `CAPS` bit 1 (flush before a new game / core) | as nes `karabas_minig_top.v` |
   | `hdf_ata` | on `SDC_*` as the floppies (its slots by `SDC_SLOT`); `ENABLE_RDB(0)` for a core that is not an Amiga (no RDB looked for in sector 0: ~75 LUT, ~120 FF less) | as archie / nanomig / profi |
   | `OSD_COMMAND` + `kg_osd_overlay` | `ENABLE_OSD`, `OSD_*` to `kg_l2_osd_overlay` in the video clock (its `hs_o` / `vs_o` / `de_o` go on with `rgb_o`) | prj adds `mcu/kg_l2_osd.v`, `video/osd/kg_l2_osd_overlay.v` |
   | own activity icons of a core (profi `icons.vhd` ...) | `kg_l2_osd_overlay` `ICONS_N`, `ICON_SET` (0 floppy, 1 SD, 2 CF, 3 HDD, 4 tape), `ICON_CORNER`, `ICON_COLUMN` (a column), `ICON_SCALE`, `ICON_MARGIN`, `ICON_BOX` (0: no dark box), `ICON_COLOR` / `ICON_DIM`, inputs `icon_on` (mounted: dim) / `icon_act` (a pulse: bright), wclk | drop the own overlay; tie `icon_on` / `icon_act` to 0 when the core has none. Place them where the picture is border in every video mode (profi: a column at the right edge, scale 2, margin 4, no box) and show the user a frame |
   | `UART_*`, `ESP_*`, `MIDI_*`, `PRN_*` (kg_mcu_uart / _esp / _midi / _printer) | `ENABLE_PORTS` bit 0 / 1 / 2 / 3, `PORT_*` (one `kg_l2_port` per port: bytes of the mcu `PORT_OUT_DATA` + `PORT_OUT_WR` while `PORT_OUT_READY`, bytes to the mcu `PORT_IN_DATA` / `_WR`, `PORT_IN_FULL`; `PORT_CFG` port 0 = DLL, DLM; `PORT_STAT` port 3 = printer status); prj adds `mcu/kg_l2_port.v` | ESP of esp8266.vhd (byte held until ack): `in_wr = rx_wr && !full`, `ack = in_wr`; MIDI: `PORT_OUT_WR[2]` is `midi_wr`, `MIDI_LOST` goes |
   | `RTC_*` (kg_mcu_rtc) | `ENABLE_RTC(1)` (`RTC_SKIP_0D`, `RTC_SEND_LIMIT` as `kg_mcu`), the same `RTC_A` / `RTC_DI` / `RTC_DO` / `RTC_CS` / `RTC_WR_N`; prj adds `mcu/kg_l2_rtc.v` | none (a write of the CPU is not taken while `BUSY`, as v1) |
   | `MATRIX_CMD` / `_WR`, `DEBUG_ADDR` / `_DATA` | `ENABLE_AUX(1)`: the same ports, the same frames (`audio_peaks.v`, the matrix CTL / PIXEL / BITPLAN); prj adds `mcu/kg_l2_aux.v` | none |

   The bytes of a load come at most every 250 ns (32 MHz sck), one `LD_WR` each; `LD_START`
   is one clock after the size of a new file (the reset of what it loads into); `LD_END` one
   clock at its end. A DATA packet of another kind than the open START is dropped.
6. **core.json.** `"link": 2` at the top level, or per board (`"boards": { "minig": { "link": 2,
   ... } }`) when only some boards move; `"type": "osd"` for the bitmap OSD menu. make_core puts the bitstream of such a
   board into `BITSTREAM_LINK2` and refuses `link` 2 for `.kg1/.kg2/.kg3`.
7. **Build one board** (Mini G) while working; `make <board>-report` for LUTs and timing; check
   the `rc` of make, not only the `.par` (an ISE map crash left an old `.par` and bin), and that
   make did not skip a board (an `.ngc` newer than its sources). Map cost table `-t 2` first.
   **Go / Mini**: take their tops from the moved Mini G top, not by hand: a script of the core
   (vic20 / atari2600 / sega `mktops.py`, next `link2_tops.py`, baseconf / tsconf `mktop_go.py`)
   or `git merge-file` of (v2 Mini G, v1 Mini G, v1 board top) and the conflicts by hand. Board
   glue: INT pin (step 3), Go FT / SD2 selects, `FT_CLK_OUT` on Mini, no LED matrix on Go / Mini
   (`MATRIX_CMD` 0); Go without HDMI: `HW_ID` / `DVI_ONLY` open, the OSD over the VGA picture
   (next: over the 31 kHz scandoubler output only, its 15 kHz RGB goes without OSD). Take every
   block the modules have (HDMI, pcm5102, OSD, hid ...) instead of the core's own copies.
8. **Test on the bench** (hwq ticket, ask the user first; the firmware flash asks too):
   - copy the `.kg` under another name (`vic20l2.kg`) so the released file stays, and delete it
     after the check;
   - `kg_board.py load vic20l2.kg` with `debug=1`: the log says `MCU link v2` and
     `Link v2: core answered in N ms, caps ...`; `Link v2: N v1 frames not sent` counts the
     calls that have no v2 command yet (OSD, IMG, ...): expected, not an error;
   - keyboard (`type`, `key`), switches (`kg_board.py osd item=value`, the reset hotkey), the
     loads (`mount <FL item> <file>`), mouse / joystick (`mouse`, `pad`), the OSD (`osd`) and the
     activity icons on a capture frame;
   - then a v1 core on the same firmware, and the bench back in the boot core.

## Pitfalls seen

- A PRG loaded on vic20 with 8K RAM overwrote the screen: its header address is for an
  unexpanded machine. A machine quirk, not the link: check the test file before the link.
- `sim/mcu/run_kg_mcu_sim.sh` took every `kg_mcu*.v` and failed on `kg_mcu2.v`: list v2 files
  explicitly in scripts.
- `kg_spi_slave` cannot be used for v2 (its write handshake is made for the v1 reply word):
  `kg_l2_link` has its own shifter.
- v1 `MS_UPD`, the keyboard and uart index are TOGGLES, the v2 `MS_WR` / `KBD_WR` /
  `PORT_OUT_WR` one-clock PULSES: a core part that takes the change of a v1 toggle needs a toggle
  made from the pulse (atari2600 paddles, apple2 mouse).
- Leftover v1 nets after a merge of tops (`matrix_cmd`, `mcu_ft_sck`, `adc_in` / `esp_in` of
  HW_ID 2 / 3 only) give XST errors: grep the v1 names after the merge.
- VHDL: `(others => '0')` on a Verilog port has no type ("Type of aggregate cannot be
  determined"): write the literal (`x"00000000"`).
- Old cores with their own `hdmi.vhd` (alf): own 858 x 525 counters put the audio islands into
  the picture: no picture on a capture. Take `zhdmi` of the modules.
- Asynchronous SRAM (profi): `TS_SRAM_OUT` missed through the page decoders (DIVMMC automap ->
  write strobe). Fixed by `/WE` from an ODDR2 (low in the second half of the clock with a write)
  and the data bus driven in every CPU write cycle without the decoders. Do not put the data
  bus tristate on an ODDR2 + `IOBUF`: on Mini G that bitstream had no HDMI picture at all.
- `kg_l2_link` before #41 needed `f_clk < 4 x f_sck` (a read answered one byte early: bk at
  65 MHz); fixed in master, bk could drop its `spi_freq` 32.
