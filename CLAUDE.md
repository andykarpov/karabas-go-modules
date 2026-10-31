# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Shared FPGA modules for the Karabas Go / Mini / Mini G cores (`karabas-go-core-*`): Xilinx Spartan-6 XC6SLX25, ISE 14.7 (XST). The cores used to carry their own copies of these modules, which diverged (16 versions of `mcu.vhd` in 17 cores). This repository holds the one maintained version; the cores include it as a git submodule.

Status: stage 3 of `docs/PLAN.md` done (Russian; the analysis of the existing copies and the migration plan): `mcu.vhd` is split into `kg_mcu_link` and decoders behind `kg_mcu`; stage 4, the cores one by one: nanomig (`kg_mcu`) and profi (all of its board modules on `kg_*`, built by `src/Makefile`) are converted, tsconf is next. Follow its stages; update the plan when a decision changes. Two generations live side by side: the nanomig files with their original names (byte for byte, what the cores build today) and their `kg_*` Verilog ports, checked against them (`sim/eq`). A core moves to the `kg_*` modules when it is converted (stage 4); the old files go once no core uses them. karabas-go-core-nanomig and karabas-go-core-profi use this repository (submodule `modules/`).

How a core uses it: the submodule is at `<core>/modules` (relative URL `../karabas-go-modules.git`, so it follows the ssh or https remote of the core), and the core's XST `.prj` lists the files it needs with paths relative to its build directory (`"../modules/rtl/..."` from `src/`). Simulation scripts of the core that rewrite prj paths must handle `../modules/` as well. A converted core builds from the command line with `src/Makefile` (targets per board and step, the map / par options of its former `.xise`, which is removed; see PLAN.md 3).

The reference versions are those of `karabas-go-core-nanomig` (sibling directory `../karabas-go-core-nanomig`): its MCU link has the reliability fixes (chip select deglitch, `spi_ssel` gated during bursts, reply words popped on `do_valid`, no `di_req` in idle in `spi_slave`) that no other core has yet. Its `CLAUDE.md` documents why each of them was needed.

## Related repositories (siblings in `..`)

- `karabas-go-core-*`: the cores that use these modules.
- `karabas-go-firmware`: the MCU side of the link. `src/config.h` has the command codes, `docs/protocol.md` and `docs/burst_protocol.md` the protocol. A change of the link here has to match it.
- `karabas-go-tools`: `make_core.py` (packs the bitstream and ROMs into `.kg1/.kg2/.kg3`).

## Layout (see docs/PLAN.md section 3)

Now (old file -> its `kg_*` replacement):
- `rtl/mcu`: `mcu.vhd` -> `kg_mcu` (same port names; built from `kg_mcu_link`, the transport with the reply queue and the chip select filter, and the decoders `kg_mcu_ctl`, `_hid`, `_loader`, `_rtc`, `_uart`, `_img`, `_debug`, `_esp` (the ESP8266 uart of the menu, `ENABLE_ESP`), `_midi` (MIDI IN of a USB keyboard, CMD_MIDI 16, `ENABLE_MIDI` for caps bit 4) on its frame bus, and `ENABLE_FLASHBOOT` (CMD_FLASHBOOT to the mcu, the core reload of next); command codes in `kg_mcu_cmds.vh`, which must match `src/config.h` of the firmware), `spi_slave.vhd` -> `kg_spi_slave`, `burst_rx.vhd` -> `kg_burst_rx`, `img_sdc.v`, `kg_bk_ram` (the backup RAM of a cartridge, a `.sav` file on the file mounter: `CMD_BK_MOUNT` / `CMD_IMG_FLUSH`, `ENABLE_BK` of `kg_mcu` for caps bit 3; it owns the img reply queue; `sim/mcu/tb_bk.v`).
- `rtl/mem`: `dpram.v` (-> `kg_tdpram` with one clock), `fifo.v` -> `kg_fifo`; `kg_async_fifo` (two clocks, Gray pointers); the coregen replacements `kg_spram`, `kg_sprom`, `kg_sdpram`, `kg_tdpram`, `kg_dist_sdpram`, `kg_dist_spram`.
- `rtl/clk`: `kg_pll`, `kg_dcm`. `rtl/ctl`: `kg_soft_switches` (the `soft_switches.vhd` of the cores), `kg_sync` (synchroniser of static signals: `DVI_ONLY` of `kg_mcu` into the pixel clock of HDMI). `rtl/hid`: `kg_cursor` (their `cursor.vhd`).
- `rtl/audio`: `pcm5102.v` -> `kg_pcm5102` (sends bit 0, see its header), `dac.vhd` -> `kg_sigma_delta_dac`, `audio_peaks.v`, `kg_midi_tx` (a MIDI out port: fifo + 31250 baud, the thru of the MIDI IN to the SAM2695).
- `rtl/video/hdmi`: `zhdmi_top.v`, zhdmi, `hdmi_pll.v` (one fixed frequency), `pll_reset.v`, `dvi*.vhd` (third-party VHDL, kept); `kg_hdmi_ft` (the HDMI of the Mini boards with the FT812 as the second source: the `hdmi_top.v` of menu / tsconf, `CLKRATE` / `REF_MHZ` the clock of the core) with `kg_hdmi_ft_pll` (their `hdmi_pll.v`: DCM_CLKGEN programmed once per FT frequency, `sim/hdmi/tb_hdmi_ft_pll.v`) and `kg_freq_counter` (their `freq_counter.vhd`). `rtl/video/osd`: `overlay.vhd` -> `kg_osd_overlay` (`ALWAYS_ON` and `H_DIV4_WIDTH` for the menu, `V_OFFSET_IN` for a vertical offset from the core: baseconf), `pix_doubler.vhd` -> `kg_pix_doubler`.
- `sim/` (`lint`, `mem`, `audio`, `ctl`, `hdmi`, `eq`, `mcu`, `ipcore_eq`, `run_all.sh`); `tools/coe2hex.py`.

Planned:

- `rtl/hid`: the keyboard and joystick decoders (`kg_hid_keys`, `kg_joy_map`), `kg_usb_ps2`; `rtl/audio`: `kg_audio_lpf`.
- `boards/{go,mini,minig}`: pin constraints (`pins.ucf`, LOC/IOSTANDARD only) per board.
- `prj/kg_modules.prj`: the source list a core's build script appends to its own prj.
- `tools/`: `coe2hex.py` and other helpers.

## Conventions

- **Module names start with `kg_`**, so they do not collide with the cores' own modules (`zxnext/*` of the next core has its own `dpram`, `dac`, `spi_master`), coregen cores or upstream code.
- **Verilog-2001 that XST accepts.** No declarations in unnamed blocks (name the block), no `'1` literals, no `` `default_nettype none `` headers, no SystemVerilog. New modules are Verilog; third-party VHDL (zhdmi, TMDS encoder) stays VHDL until it has tests.
- **No coregen (ipcore).** Memories and FIFOs are inferred RTL; clocks instantiate `PLL_BASE` / `DCM_SP` directly (`kg_pll`, `kg_dcm`). ROM contents come from `.hex` files through `$readmemh` (`tools/coe2hex.py` converts `.coe`).
- **Optional features are parameters (`ENABLE_*`) with `generate`**, so a core that does not use a feature does not build it. Several cores fill 96-99% of the slices: check LUT counts when a module changes.
- **Interfaces are stable.** A port change is a major version (tag `vX.Y`, `CHANGELOG`); keep a compatibility wrapper for at least one major version. Cores pin the submodule commit, so a change here reaches a core only when it updates its submodule.
- Imported code keeps its upstream form; local changes are marked with a `// karabas:` comment that says why.
- Commit messages explain why a change was needed and what it costs or changes in behaviour (latency, LUT counts before and after), and say "No functional change." when that is the case.

## Clock crossings

- The outputs of `kg_mcu` (`DVI_ONLY`, `HWID`, soft switches, OSD commands, loader writes) are registers of its `CLK`. A core that uses one in another clock goes through a synchroniser or a handshake there; a constraint is not a fix for a missing one.
- Static or slow signals (settings, enables, a flag that holds for many clocks): `kg_sync #(.W(n))` on the destination clock, `STAGES` 2 (3 for a fast destination clock). Each bit is synchronised on its own: a vector that changes may be seen half old, half new for a clock, so a counter or a data word crosses with `kg_async_fifo` (Gray pointers) or a toggle handshake (`kg_mcu_link`, `kg_spi_slave`), never with `kg_sync`.
- `kg_sync` has `ASYNC_REG` (map keeps the stages together and moves no logic into them) and `SHREG_EXTRACT = "NO"`: the cores synthesize with `-shreg_extract YES`, and a chain of flip-flops without it becomes an SRL, which is no synchroniser. Check in the `.twr` / `.map` of the core that `<inst>/s_0`, `s_1` are flip-flops.
- Constraints of the core for the path into the first stage: FROM-TO DATAPATHONLY bounded by one period of the destination clock (or TIG); the stages themselves are paths in one clock. Constrain from a PERIOD on CLK_50MHZ derived onto the PLL / DCM outputs, as the converted cores do (profi, tsconf, nes): separate PERIODs on each PLL output leave the crossings unanalysed and hide paths like the one below.
- HDMI: anything of the core clock that selects or gates the TMDS words (`dvi_only ? dvi_* : tmds_*`, `audio_en` of zhdmi) reaches the 5x serialiser clock. Two dividers of one VCO give it a phase of a VCO step or less (nes: 0.2 ns, -2.9 ns slack): take it from a pixel clock register, i.e. `kg_sync` into the pixel clock first.

## Verifying a change

`sim/run_all.sh` runs every test (about three minutes); each test prints `<tb>: 0 errors`. The CI (`.github/workflows/sim.yml`) runs the ones without ISE: lint, memories, audio, the `sim/eq` comparisons that go through ghdl. Tools: verilator, iverilog, ghdl (system packages), ISE 14.7 in `/opt/Xilinx/14.7` for ISim. If a tool is missing, ask the user to install it.

- `sim/lint/run_lint.sh`: verilator `-Wall` on the `kg_*.v` files (no warning allowed), verilator on the imported Verilog (errors fail, warnings are listed), ghdl analysis of the VHDL (`ghdl_check.py`: VHDL-93 or 2008, ISE takes constructs of both; `spi_slave.vhd` only as its entity, ghdl rejects its case choices). Xilinx primitives and the VHDL entities used from Verilog are black boxes (`xilinx_stubs.v`, `unisim_stubs.vhd`).
- `sim/mem/run_mem_sim.sh` (iverilog): the `kg_*` memories, `dpram.v` and `fifo.v` against the model in `tb_mem.v`, random stimulus, every output after every edge; `tb_async_fifo.v`: `kg_async_fifo` with four pairs of clocks (same frequency and two phases, either side faster) and a stream at the same frequency, every word in order, `rcount`, full / empty.
- `sim/ctl/run_ctl_sim.sh` (iverilog): `tb_sync.v`, `kg_sync` against a model of its stages with d changing on another clock.
- `sim/audio/run_audio_sim.sh` (iverilog): `tb_pcm5102.v` decodes the I2S stream (of `pcm5102.v` bits 15..1 only, bit 0 is never sent; of `kg_pcm5102` all 16 bits, whole frames, din changing with the falling bck), `tb_audio_peaks.v` the frames of the level meters.
- `sim/eq/run_eq.sh`: each `kg_*` port against the old module, the same random stimulus, every output after every clock (`eq_check.vh`; an old output still X, a VHDL signal without initial value, is not compared). iverilog with the VHDL turned into a netlist by `ghdl --synth` (dac, pix_doubler, burst_rx, soft_switches and cursor of other cores, copied to `sim/eq/ref`), ISim for `spi_slave` (ghdl rejects it), `overlay` (latches; a cell after a popup / overlay switch is not compared, see `kg_osd_overlay.v`) and `mcu.vhd` against `kg_mcu` with the nanomig configuration (`tb_eq_mcu`; random frames, bursts with spikes, every core-side source; the stimulus must not fill the reply queue: 511 words in `fifo.v`, 512 in `kg_fifo`). `EQ_ONLY=<tb>` runs one. A rewrite of another module gets its testbench here.
- `sim/mcu/run_kg_mcu_sim.sh` (iverilog, also in the CI): `tb_kg_mcu.v` (what `mcu.vhd` of nanomig does not have: the tsconf features, the file loaders of rk86 / alf, the chip select filter, a full reply queue) and `tb_mcu.v` / `tb_img.v` with `kg_mcu` (`-DKG_MCU`).
- `sim/mcu/run_mcu_sim.sh` (ISim): `tb_mem.v` with the VHDL models `dpram_sim.vhd` / `fifo_sim.vhd` (ISim cannot elaborate the Verilog ones from VHDL with open ports), `tb_mcu.v` (every command of `mcu.vhd`, the reply queue, loaders classic and burst, rtc, CAPS, spikes on `MCU_SS` during bursts), `tb_img.v` (the file mounter). The spike test fails with the link of the other cores (old `spi_slave`, a reply word taken on `di_req`, no `spi_ssel` gating) and passes with any one of the three fixes; the glitch of the combinational `di_req` is not visible in RTL simulation.
- `sim/ipcore_eq/run_ipcore_eq.sh` (ISim, needs the sibling cores): the `kg_*` memories and clocks against the coregen cores they replace (models from `$XILINX/verilog/src/XilinxCoreLib`, which ISE has as source only). Memories: random stimulus, every output every clock; clocks: every edge. When a core replaces another coregen core, add the pair there first.
- The coregen models zero their memories and outputs; the `kg_*` memories do the same in simulation (a loop hidden from XST by `translate_off`, as XST limits loop iterations) and XST starts the block RAMs at 0, so both match on the FPGA.
- A test is only worth something if it fails without the code it covers: break the module in a scratch copy (`cp -r rtl sim` elsewhere, edit, run the script there, one copy per run) and see the test fail.
- A checking task called from more than one process must be `task automatic`: iverilog may switch threads after the arguments of a static task are set, and a call then checks the arguments of another (this hid every error of `upd` in `tb_eq_soft_switches` until it was found by a mutation).
- Inputs of a testbench for a VHDL and a Verilog module change at the falling clock: a change at the rising edge reaches the processes of the two languages in a different order in ISim.
- A VHDL signal without an initial value is U in ISim; an `isim force` that ends lets it fall back to its U driver, so hold the force (`tb_eq_overlay`).
- Check what XST infers ("Advanced HDL Synthesis Report" of the `.syr`: block or distributed RAM, size, write-first / read-first) and the RAMB16 / RAMB8 count against the coregen build.
- A rewrite of an existing module is checked against the old one with the same stimulus, output by output, clock by clock (`sim/eq`), and synthesized alone against it with XST (LUTs, registers; `-iobuf NO`). A register that has an initial value other than its asynchronous reset value costs XST latches, and any initial value can keep it from inferring an accumulator (`kg_sigma_delta_dac`).
- XST builds the write of a part of a vector (`kb[n*8 +: 8] <= d`, `joy[12:8] <= d`) as a mux over the whole vector, a LUT per bit instead of a clock enable: use one register per field (the decoders of `kg_mcu`; 130 LUTs on the nanomig configuration). Standalone numbers of a small module are noisy (Reduce Control Sets moves enables into LUTs on its own); the measure that counts is the build of a core.
- Build at least one core that uses the module and compare utilization (`*_map.mrp`) and timing (`*.par`, "All constraints were met") with the build before the change.
- Changes to the MCU link need a check on hardware with the firmware: rom loading, OSD, keyboard, joysticks, file mounter.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`, `link.sh` there makes the links). Its `MEMORY.md` is split by repo; commit and push it after every memory change.
