# karabas-go-modules

Shared FPGA modules for the [Karabas Go](https://github.com/andykarpov/karabas-go) / Mini / Mini G cores (Spartan-6 XC6SLX25, ISE 14.7).

The cores include this repository as a git submodule in `modules/` and list the files they use in their XST `.prj` (paths relative to the build directory, for example `"../modules/rtl/mcu/mcu.vhd"`).

| Directory | Contents |
|---|---|
| `rtl/mcu` | MCU link (SPI commands of [karabas-go-firmware](https://github.com/andykarpov/karabas-go-firmware) `docs/protocol.md`, `docs/burst_protocol.md`): `mcu.vhd` / `kg_mcu` (= `kg_mcu_link` + the decoders `kg_mcu_*`), `spi_slave.vhd` / `kg_spi_slave`, `burst_rx.vhd` / `kg_burst_rx`, `img_sdc.v` (file mounter as a sector interface) |
| `rtl/mem` | `dpram.v`, `fifo.v` / `kg_fifo`, `kg_async_fifo` (two clocks); inferred replacements of the coregen memories: `kg_spram`, `kg_sprom`, `kg_sdpram`, `kg_tdpram` (byte write enables), `kg_dist_sdpram`, `kg_dist_spram` |
| `rtl/ctl` | `kg_soft_switches` (OSD switches of the mcu), `kg_sync` (static signals into another clock: `DVI_ONLY` of `kg_mcu` into the HDMI pixel clock) |
| `rtl/hid` | `kg_cursor` (absolute mouse position for the Kempston mouse) |
| `rtl/clk` | `kg_pll` (PLL_BASE), `kg_dcm` (DCM_SP): the coregen clocking wizard cores with the same parameters |
| `rtl/audio` | `pcm5102.v` / `kg_pcm5102` (I2S DAC), `dac.vhd` / `kg_sigma_delta_dac`, `audio_peaks.v` (level meters of the MCU) |
| `rtl/video/hdmi` | `zhdmi_top.v` and the zhdmi HDMI transmitter, `hdmi_pll.v`, `dvi*.vhd` |
| `rtl/video/osd` | `overlay.vhd` / `kg_osd_overlay` (OSD menus of the MCU), `pix_doubler.vhd` / `kg_pix_doubler` |

`tools/coe2hex.py` converts a coregen `.coe` into the `$readmemh` file of the `INIT_FILE` parameters.

The `kg_*` modules are the Verilog versions of the files next to them (`a / b` above), checked against them; the cores move to them one by one.

Tests: `sim/run_all.sh` (lint with verilator and ghdl, the memories and audio modules with Icarus Verilog, each `kg_*` port against the module it replaces; with ISE 14.7 also the MCU link against a model of the firmware and the `kg_*` modules against the coregen cores they replace). The CI runs the part without ISE.

The modules came from [karabas-go-core-nanomig](https://github.com/andykarpov/karabas-go-core-nanomig), whose MCU link has the latest fixes. The plan for the other cores and the next steps (Verilog rewrite, split of `mcu`, removal of the coregen cores) is in [docs/PLAN.md](docs/PLAN.md).
