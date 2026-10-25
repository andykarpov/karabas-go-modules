# План объединения общих модулей karabas-go-core-*

Состояние на 2026-10-18. Эталон — `karabas-go-core-nanomig` (master 90dc1bc, 2026-10-17).

Цель: вынести общие модули ядер Karabas Go / Mini / Mini G в этот репозиторий, подключать их во все ядра и сопровождать из одного места. Попутно перевести свои модули на Verilog-2001 и отказаться от Xilinx coregen (ipcore).

## 1. Инвентаризация

Проанализировано 17 ядер `karabas-go-core-*`. Версии сравнивались после нормализации (CRLF и пробелы в концах строк убраны).

| Модуль | Версий | Эталон и замечания |
|---|---|---|
| `mcu.vhd` | **16 на 17 ядер** (одинаковы только alf и alf128) | nanomig: 660 строк, burst, IOCTL, IMG_*, CAPS. Больше всего функций у tsconf: PS/2 и XT-сканкоды, UART с DLM/DLL, DEBUG, matrix и peaks. |
| `spi_slave.vhd` | 3 | nanomig: исправлен `di_req` в idle. next186 — своя версия. Остальные 15 ядер одинаковы и без исправления. |
| `burst_rx.vhd` | 1 | Одинаков в 7 ядрах (alf, alf128, nanomig, nes, profi, rk86, tsconf). |
| `hid_parser.vhd` | 10 | Своя логика в каждом ядре: матрица ZX, NES, ALF, RK86; в tsconf и baseconf к нему прикручен RTC. В nanomig вместо него `hid_amiga.v`. |
| `soft_switches` | 9 (7 VHDL, 2 Verilog) | Механизм один (регистр по `cmd[15:8]`), различается раскладка. В nanomig код встроен в top. |
| `overlay.vhd` | **13** | nanomig и tsconf: RGB 24 бита, HS/VS, автомасштаб; в nanomig есть `H/V_OFFSET`. profi и next: 9-битный вход, свой тайминг. В старых ядрах используется coregen `osd_vram` / `rom_font`. |
| `zhdmi_top.v` | 5 | `ds80` (nanomig, profi); `clk_ref` + мультиплексор FT812 (tsconf, menu, baseconf, vt100); `CLKRATE` (spec256, next186). |
| `zhdmi_tx.vhd` | 3 | nanomig, profi и next186 переключаются на DVI при `audio_en=0`; в spec256 есть `FORCE_DVI`. Остальные файлы `zhdmi_*` одинаковы. |
| `hdmi_pll.v` | 10 | По сути это частоты конкретного ядра. |
| `audio_samplerate.v` | 3 | |
| `pll_reset.v` | 2 | |
| `dpram.v` | 5 | Двухтактная версия есть только в pdp2026. Во всех версиях `mem[0:NUMWORDS]`, то есть на одно слово больше нужного. |
| `fifo.v` | 2 | В alf, alf128, nes, test, next и profi есть ещё coregen `ipcore_dir/fifo.v`. |
| `pcm5102.v` | 4 | Индекс `r2c[16 - …]` даёт 16 при ширине `[15:0]`. Проверено `tb_pcm5102` (этап 1): задержка I2S на один такт сделана правильно, биты 15..1 доходят, но бит 0 не передаётся никогда. В его слоте индекс 16: в симуляции X, после XST — бит 0 того же канала, который к тому же меняется одновременно с фронтом bck. При смене сэмпла бит 1 правого канала тоже меняется на фронте bck. Исправить в `kg_pcm5102` (`STRICT=1` в тестбенче). |
| `dac.vhd`, `dvi*.vhd` | 1 | Одинаковы везде. |
| `cursor.vhd` | 5 | |
| `usb_ps2_lut`, `hid_typematic`, `serial_mouse_convertor`, `dot_matrix` | по 2 | |
| `audio_peaks.v`, `audio_filter.v`, `img_sdc.v` | 1 | Есть только в nanomig, почти не зависят от Amiga. |
| UCF-распиновка | 3–4 на плату | Отличается в основном количеством пинов, а не их привязкой. |

**Главный вывод.** Исправления надёжности SPI-линка есть только в nanomig:
1. фильтр коротких импульсов на CS (3 такта) в top;
2. `spi_ssel` закрыт во время burst;
3. слово из очереди берётся по `do_valid`, а не по `di_req`;
4. исправлен `di_req` в idle в `spi_slave`.

Ядра с burst (tsconf, profi, alf, alf128, nes, rk86) подвержены тем же потерям кадров.

**Мелочи:**
- В firmware (`src/config.h`) `0x09` — это `CMD_SPI_CONTROL`. baseconf, menu, tsconf, vt100 и next186 объявляют под этим кодом `CMD_FT`/`CMD_FT_DATA` (`0x09`/`0x0A`). Совместимость нужно проверить.
- Загрузчиков три поколения: ROMLOAD (`06`–`08`), FILELOAD (`0C`–`0E`), IOCTL (`50`–`55`).
- В next есть свои `dpram.vhd`, `spi_master.vhd` и `dac.vhd` в `zxnext/`. Общие модули с такими же именами столкнутся с ними в библиотеке `work`.
- alf и alf128 указывают на один remote.
- pdp2026 лежит в чужом репозитории (tsybulin): изменения туда только через PR.
- У baseconf и vt100 нет remote.

## 2. Принципы

1. **В общий репозиторий идёт только то, что не зависит от машины**: линк с MCU, память, аудио- и видеовыход, OSD, разбор HID до уровня событий, файловый монтировщик. Раскладки клавиатуры, назначение soft switches и PLL ядра остаются в ядрах, общий модуль только параметризуется.
2. **Префикс `kg_` у всех модулей.** Так не будет столкновений с `zxnext/*`, coregen и апстримом (Minimig, TS-Conf).
3. **Verilog-2001 под XST**: без деклараций в неименованных блоках, без `'1`, без `` `default_nettype none `` и без SystemVerilog.
4. **Ненужное выключается параметрами `ENABLE_*` через `generate`**, а не обрезается при map. Это важно для ядер на 96–99% slice.
5. **Сторонний VHDL (zhdmi, TMDS) на Verilog сразу не переписываем.** Он рабочий и одинаковый во всех ядрах. Свои модули переписываем.
6. **Без coregen.** Память, FIFO и PLL пишутся в RTL или инстанцируют примитивы Spartan-6 напрямую.

## 3. Структура репозитория

```
karabas-go-modules/
  rtl/
    mcu/    kg_mcu.v            — совместимая обёртка (порты как у mcu.vhd nanomig)
            kg_mcu_link.v       — spi_slave + burst_rx + фильтр CS + очередь TX + шина кадров
            kg_spi_slave.v      kg_burst_rx.v   kg_cs_deglitch.v
            kg_mcu_cmds.vh      — коды команд, сверенные с firmware src/config.h
            kg_mcu_ctl.v        — SWITCHES, OSD, HW_SETUP, INIT_*/BUSY, CAPS, BTNS, CONTROL (FT/SD2)
            kg_mcu_hid.v        — KBD, MOUSE, JOY, PS2_SCANCODE
            kg_mcu_loader.v     — ROMBANK/ROMDATA/ROMLOADER + FILE* + IOCTL* (одна шина записи)
            kg_mcu_rtc.v        — dpram RTC + отправка CMD_RTC
            kg_mcu_uart.v       kg_mcu_debug.v   kg_mcu_matrix.v
            kg_mcu_img.v        — IMG_* (file mounter)   kg_img_sdc.v
    hid/    kg_hid_keys.v       — отчёт USB → события press/release (код + модификаторы)
            kg_joy_map.v        — Kempston/Sinclair/Cursor/… по JOY_TYPE
            kg_usb_ps2.v (+lut) kg_ps2_typematic.v   kg_cursor.v
            kg_kempston_mouse.v kg_serial_mouse.v
            keymaps/            — таблицы ZX-матрицы, Amiga и т.д.
    ctl/    kg_soft_switches.v  — N 8-битных регистров, плоский выход + строб изменения
    mem/    kg_fifo.v  kg_async_fifo.v  (dpram → kg_tdpram с одним клоком, двухклоковый — kg_tdpram)
            kg_spram.v  kg_sprom.v  kg_sdpram.v  kg_tdpram.v  kg_tdpram_asym.v  kg_dist_sdpram.v  kg_dist_spram.v
    clk/    kg_pll.v (PLL_BASE + BUFG)  kg_dcm.v (DCM_SP)  kg_pll_reset.v
    audio/  kg_pcm5102.v  kg_sigma_delta_dac.v  kg_audio_peaks.v  kg_audio_lpf.v
    video/  hdmi/ (zhdmi_*.vhd как есть, kg_hdmi_top.v, kg_hdmi_pll.v, kg_audio_samplerate.v, kg_video_mux.v)
            osd/  kg_osd_overlay.v  kg_pix_doubler.v
  boards/   go/ mini/ minig/  — pins.ucf (только LOC/IOSTANDARD), шаблон top
  prj/      kg_modules.prj    — список файлов, пути от корня репозитория
  sim/      модели (MCU firmware, SDRAM, SRAM), тестбенчи, run-скрипты (ISim + iverilog)
  tools/    coe2hex.py, генерация prj
  docs/     соответствие команд firmware docs/protocol.md, CHANGELOG
```

### Подключение к ядрам

- Git submodule в `<core>/modules`: каждое ядро зафиксировано на своём коммите, сборки воспроизводимы. Соседний checkout через symlink (как сейчас с karabas-go-tools в nanomig) для RTL не годится.
- XST-prj не умеет include. Решено на этапе 0: ядро перечисляет нужные файлы в своём prj с путями `"../modules/rtl/..."`. Наборы файлов у плат разные (Go без HDMI), а явный список проще, чем склейка фрагментов. `prj/kg_modules.prj` — только справочный список.
- В `.xise` пути относительные (`../modules/rtl/...`), пока ядро не перешло на Makefile; при переводе `.xise` удаляется.
- **Сборка из командной строки — `src/Makefile` ядра** (решено 2026-10-18 при переводе profi, правило для всех ядер). Цели `make go|mini|minig` и шаги `<board>-xst`, `-impl`, `-core`, `-report`. Входы `karabas_<board>.prj`, `.xst`, `.ut`, `.ucf` лежат в git, опции map/par переносятся из `.xise` платы, сам `.xise` удаляется (одна точка правды — prj). Шаг пересобирается, когда изменился любой файл из prj. Makefile заменяет `build_*.sh` (nanomig перевести на него).
- ngdbuild принимает несколько `-uc`: `modules/boards/<board>/pins.ucf` плюс `timing.ucf` самого ядра.

## 4. Рефакторинг mcu

`mcu.vhd` сейчас монолит, и в каждом ядре у него свой набор портов. Его стоит разбить на два слоя.

**Слой 1: `kg_mcu_link`.** SPI-slave, burst-приёмник, фильтр CS, очередь TX 512×24 и NOPE против опустошения очереди.
- Выход — шина кадров `rx_stb, rx_cmd[7:0], rx_addr[7:0], rx_data[7:0]` и burst `bst_stb, bst_type, bst_addr[31:0], bst_data`.
- Вход TX — арбитр на K портов `req / data[23:0] / ack` с фиксированным приоритетом (сейчас это цепочка `elsif`).
- Сюда входят все четыре исправления из nanomig и параметр `BURST_MAX_MHZ`.

**Слой 2: декодеры функций.** Каждый слушает шину кадров и, если ему нужно отвечать (`ctl` → CAPS, `rtc`, `uart`, `img`, `matrix` / peaks), подключается к TX. CAPS собирается автоматически из включённых `ENABLE_*`.

**`kg_mcu` — совместимая обёртка** с параметрами `ENABLE_MOUSE`, `ENABLE_RTC`, `ENABLE_UART`, `ENABLE_IMG`, `ENABLE_IOCTL`, `ENABLE_FILELOAD`, `ENABLE_FT`, `ENABLE_SD2`, `ENABLE_PS2`, `ENABLE_DEBUG`, `ENABLE_MATRIX`, `ENABLE_BURST`, `ENABLE_ESP` (menu).
- Порты — надмножество портов nanomig и tsconf, имена те же. В top меняется только имя модуля.
- Отдельные декодеры можно ставить и без обёртки.

**Что меняется по пути:**
- Три загрузчика сводятся в `kg_mcu_loader` с одной шиной записи: `ld_wr, ld_addr[31:0], ld_data, ld_target{rom,file,ioctl}` и `ioctl_slot/size/ext/active`. Нужно сохранить семантику `ROMLOAD_WR` по смене адреса и `ioctl_wr` на каждый байт (см. комментарии в nanomig `mcu.vhd`).
- Портов `buffer` не будет, поэтому `mcu_sim_wrap.py` больше не нужен.
- `MS_UPD` как toggle остаётся в совместимой обёртке, в новых модулях вместо него строб.
- Константы команд — в `kg_mcu_cmds.vh`, сверенном с `config.h`. В firmware добавить ссылку на этот файл.

**Тонкое место — `spi_slave`.** Сдвиговый регистр работает в домене SCK, потому что burst идёт на 32 МГц при `clk_sys` около 28 МГц, и пересэмплирование невозможно. Порт на Verilog обязан сохранить эту архитектуру: сдвиг по SCK, слово передаётся через toggle и синхронизатор.

## 5. Остальные модули

- **soft_switches** → `kg_soft_switches #(.N(32), .INIT(...))` с выходом `regs[N*8-1:0]` и стробом `upd`. Ядро нарезает поля через `assign`. Обработку повтора команды (`prev_command`) сохранить.
- **hid_parser** делится на две части:
  - `kg_hid_keys`: сравнение отчётов, debounce 200 мкс, интервал между событиями, как в `hid_amiga`;
  - раскладку ядра: таблицу или ROM вида «USB-код → матрица ZX, Amiga и т.д.».

  Для ZX-ядер (profi, tsconf, baseconf, spec256, test) можно сделать общий `kg_zx_keymatrix`. NES, ALF и RK86 сохраняют свои раскладки. `kg_joy_map` один для всех. JOY 13 бит; у next и test 12 бит дополняются нулём.
- **overlay**: эталон — nanomig (RGB 24 бита, HS/VS, автомасштаб, `H/V_OFFSET`). К нему добавляются `DEFAULT` из menu и `OSD_ACT` из rk86. Для profi и next (9-битный вход) — отдельный переходник, или они пока остаются в ядре.
- **HDMI**: `kg_hdmi_top` на `zhdmi_tx` из nanomig (DVI-fallback) плюс `FORCE_DVI` из spec256.
  - Режим частоты задаётся параметром `CLK_MODE`: `ds80`, фиксированный `CLKRATE` или вход `freq`.
  - Мультиплексор FT812 (`ft_rgb/ft_sel`) выносится в `kg_video_mux`.
  - `hdmi_pll` получает параметры, а 10 версий превращаются в таблицу значений в ядрах.
- **pcm5102** → `kg_pcm5102` с параметром делителя и сбросом. Сначала тестбенч на формат I2S, потом исправление индекса.
- **dpram**: заменяется на `kg_tdpram` (тот же клок на оба порта; два клока, как в pdp2026, тоже он). Отдельный `kg_dpram` не нужен.
- **fifo** → `kg_fifo` (уже на Verilog). Coregen-fifo заменить с проверкой ресурсов.
- В общие уходят модули из nanomig:
  - `audio_peaks` (уровни для firmware нужны всем ядрам);
  - `audio_filter` → `kg_audio_lpf` с параметром среза;
  - `img_sdc` (монтировщик образов пригодится tsconf и profi).

## 6. Отказ от ipcore (coregen)

### Что используется в сборке (prj / xise)

| Ядро | ipcore | Где используется |
|---|---|---|
| test | `queue`, `rtc`, `pllx5`, `pll` | `mcu.vhd`, top |
| pcxt | `queue`, `rtc` | `mcu.vhd` |
| vt100 | `osd_vram`, `rom_font`, `pll` | `overlay.vhd`, `vt_top.v` |
| alf, alf128 | `osd_vram`, `rom_font`, `pllx5`, `framebuffer` (SDP 64K×6) | `overlay*.vhd`, top, `vga.vhd` |
| nes | то же + `nes_clk`, `ram2k`, `ram8k` (SP) | `memorycontroller.v` |
| rk86 | `osd_vram`, `rom_font`, `queue`, `pll`, `pllx5`, `font` (ROM, coe), `rambuffer` (TDP 256K×1) | `rk_video.v` |
| pdp2026 | `pll`, `bootrom`, `ledfont` (ROM, coe), `sectorbuf` (TDP 256×16) | `pdp2011.v`, `sdspi.v`, `icons.v` |
| next | `queue`, `rtc`, `pll_midi` (DCM), `sdpbram_16k_8` (ENB), distributed `sdpram_128_8`, `sdpram_16_9`, `sdpram_64_9`, `spram_320_9`, `keyjoy_sdpram_64_6` (coe) | `mcu.vhd`, `zxnext/video/*`, `uart.vhd`, `membrane_stick.vhd` |
| next186 | `dcm`, `dcm_dsp`, `cache` (TDP 32×4096, ENB), `DAC_SRAM` (TDP 8/32), `datamem16` (SDP 32/16), `instrmem`, `sr_font` (coe), async FIFO `fifo` (16→32), `sndfifo` (32×4096, счётчики), `qdsp` (17×16 distributed) | `ddr_186.v`, `DSP32.v`, `vga.v`, `soundwave.v`, `cache_controller.v` |
| baseconf | `fifo`, `fifo2`, `osd_vram`, `pll`, `queue`, `rom_font`, `rtc` — только в устаревших `karabas_go_top.prj` / `karabas_mini_top.prj` | `ipcore_dir` нет, RTL уже на своём `fifo.v`. Вычистить prj. Ядра пока нет, см. этап 4 п. 4. |

В сборке без ipcore: nanomig, profi, tsconf, menu, spec256, sdram-test. В profi остался неиспользуемый `ipcore_dir`.

`UART_8250.v` в next186 лежит в `ipcore_dir`, но это обычный исходник из opencores: просто перенести в `rtl/`. `q1` и `q16` есть в prj next186, но где они создаются, не найдено. Скорее всего, это мусор; проверить.

### Чем заменять

**A. Исчезает само при переходе на общие модули:**
- `queue` (24×512) → `kg_fifo` внутри `kg_mcu_link`;
- `rtc` (SDP 256×8) → `kg_sdpram` в `kg_mcu_rtc`;
- `osd_vram` (1K×16), `rom_font` (`osd_font.coe`), `rom_font2` (`icons.coe`) → `kg_osd_overlay`;
- `pllx5` (DCM_SP ×5 для HDMI) → `kg_hdmi_top` / `hdmi_pll`.

**B. Обычная память → универсальные модули `rtl/mem/`:**
- `kg_spram`: `ram2k`, `ram8k`;
- `kg_sprom #(.INIT_FILE)`: `font`, `bootrom`, `ledfont`;
- `kg_sdpram #(.INIT_FILE)` с `en`: `framebuffer`, `sdpbram_16k_8`, `instrmem`;
- `kg_tdpram`: `sectorbuf`, `rambuffer`, `cache` (ENB), `sr_font` (init);
- `kg_dist_sdpram` / `kg_dist_spram` (асинхронное чтение, LUT RAM): `sdpram_*`, `spram_320_9`, `keyjoy_sdpram_64_6`;
- `tools/coe2hex.py`: перевод `.coe` в `.hex` для `$readmemh`.

Латентность совпадает: у этих blk_mem_gen выходные регистры выключены, то есть чтение за 1 такт.

**C. Сложные случаи (next186):**
- Асимметричная ширина (`DAC_SRAM` 8/32, `datamem16` 32/16): память на широкое слово с byte-enable и мультиплексором. Если не уложится — явный `RAMB16BWER` в `kg_tdpram_asym`.
- Async FIFO (`fifo` 16→32, `sndfifo`, `qdsp`): `kg_async_fifo` с Gray-указателями, соотношением ширин и счётчиками rd/wr, плюс TIG/DATAPATHONLY на синхронизаторы. Обязательны тестбенч с разными частотами и проверка на железе. *`kg_async_fifo` с одной шириной сделан 2026-10-19 для tsconf (видео FT812 → пиксельный клок HDMI), тест `sim/mem/tb_async_fifo.v`; соотношение ширин и счётчик записи — когда понадобятся next186.*

**D. PLL и DCM.** «MMCM» в `.xco` — просто метка, внутри сгенерированных `.v` стоят `PLL_BASE` / `DCM_SP`. Их можно заменить один к одному на `kg_pll` / `kg_dcm`, перенеся коэффициенты из текущих `.v`. Например, у alf `pll`: `DIVCLK=2, MULT=37, OUT=11/116/58/77`.

**E. Уборка.** Удалить неиспользуемые `ipcore_dir` и устаревшие prj baseconf. После этого симуляции не нужна XilinxCoreLib.

### Проверка каждой замены
1. Число RAMB16/RAMB8, LUT RAM и DCM/PLL в `_map.mrp` до и после. Если выведенная память ушла в LUT, ищи асинхронное чтение или лишние порты.
2. Тестбенч модуля против поведенческой модели coregen (из `ipcore_dir/*.v`, пока она есть).
3. Проверка на железе и timing report: констрейнты на сгенерированные клоки должны сохраниться.

## 7. Этапы

0. **Скелет репозитория.** *Сделано 2026-10-18 (nanomig PR #8).* Перенести версии из nanomig как есть: без переименований и правок, VHDL остаётся VHDL. Перевести nanomig на submodule. Критерий: та же утилизация в `_map.mrp`, тайминги выполнены, `nanomig.kg3` работает на железе. Сразу добавить простые модули из 6.B и 6.D (`kg_spram`, `kg_sprom`, `kg_sdpram`, `kg_tdpram`, `kg_dist_*`, `kg_pll`, `kg_dcm`) и `coe2hex.py`.
1. **Тесты.** *Сделано 2026-10-18.* `sim/run_all.sh`:
   - линт: verilator (`kg_*` с `-Wall` без предупреждений, импортированный Verilog — только ошибки), ghdl;
   - память и fifo против модели (iverilog), включая VHDL-модели для ISim;
   - `pcm5102`, `audio_peaks` (iverilog);
   - `tb_mcu` (все команды, очередь ответов, загрузчики classic и burst, RTC, CAPS, иголки на `MCU_SS` во время burst) и `tb_img` из nanomig (ISim).

   CI на GitHub Actions — всё, что без ISE.
   - Из nanomig перенесён только `tb_img`: `run_hid_sim` и `run_audio_sim` тестируют `hid_amiga.v` и `audio_filter.v`, которые пока остаются в ядре. Остальное — тесты ядра целиком.
   - Тест на иголки падает на линке остальных ядер (старый `spi_slave`, съём слова по `di_req`, без гейтинга `spi_ssel`) и проходит с любым из трёх исправлений nanomig. Глитч комбинационного `di_req` в RTL-симуляции не виден.
   - Фильтр CS (3 такта) пока в top ядра; тест на него появится вместе с `kg_mcu_link` (этап 3).
2. **Переписать на Verilog листовые модули**: `spi_slave`, `burst_rx`, `dac`, `soft_switches`, `cursor`, `pix_doubler`, `overlay`. Эквивалентность проверять в смешанном ISim: один стимул на старый VHDL и новый Verilog, сравнение выходов по тактам. *Сделано 2026-10-18.* Старые файлы остаются, пока ими собираются ядра.

   Модули и проверка (`sim/eq`): каждый `kg_*` против старого, всё в iverilog через `ghdl --synth`, кроме `spi_slave` и `overlay` (ISim). XST отдельно, LUT / регистры:

   | Старый → новый | XST: старый → новый |
   |---|---|
   | `spi_slave` → `kg_spi_slave` (режим 0, без отладочных портов) | 71 → 66 LUT, 89 FF (без репликации регистров) |
   | `burst_rx` → `kg_burst_rx` | 128 → 129 LUT, 118 → 115 FF |
   | `dac` → `kg_sigma_delta_dac` | 17 LUT, 18 FF |
   | `pix_doubler` → `kg_pix_doubler` | 55 LUT, 53 FF |
   | `overlay` → `kg_osd_overlay` | 312 → 301 LUT, 221 → 195 FF, без 37 защёлок |
   | `soft_switches` (tsconf) → `kg_soft_switches` | 48 → 52 LUT, 31 FF |
   | `cursor` (tsconf, profi, next, test) → `kg_cursor` | 34 LUT, 42 FF |
   | `pcm5102` → `kg_pcm5102` (исправлен) | 58 → 48 LUT |
   | `fifo` → `kg_fifo` (2^AW слов, `count`) | 87 → 41 LUT (24×512) |

   Находки:
   - **`overlay.vhd` читал символ и строку шрифта через защёлки** (процесс без клока). В `kg_osd_overlay` адреса комбинационные, атрибут и строка шрифта — регистры. Вывод совпадает потактно, кроме одной-двух ячеек в кадре, где переключился popup / overlay: старый держал адреса прежнего режима до своей фазы чтения. В ISim старая модель ещё и неточна (`font_word` нет в списке чувствительности).
   - **`kg_pcm5102` передаёт бит 0.** Входы защёлкиваются в начале левого слова, din меняется только по спаду bck.
   - **Варианты `soft_switches`.** pdp2026 и vt100 пишут регистр без сравнения с прежней командой, а vt100 вообще иной (сброс при команде 0). Их переводить отдельно.
   - **Вариант `cursor` из pcxt** (накопление до чтения) остаётся в ядре.
   - **Ошибка в самих тестах.** Статическая задача проверки, вызванная из нескольких процессов, в iverilog проверяла чужие аргументы. Все проверочные задачи теперь `automatic`; найдено мутацией.
3. **mcu**: слои, декодеры, обёртка `kg_mcu`. Проверка против `mcu.vhd` nanomig, затем tsconf (PS/2, XT, UART) и rk86 / spec256 (IOCTL). *Сделано 2026-10-18.*

   Устройство:
   - `kg_mcu_link`: фильтр CS (`CS_FILTER`), `kg_spi_slave`, `kg_burst_rx`, очередь `kg_fifo` 512×24, NOPE, ответ на CAPS, арбитр на `TX_PORTS` портов. `tx_grant` комбинационный: источник держит запрос до выдачи.
   - Декодеры `kg_mcu_ctl`, `_hid`, `_loader`, `_rtc`, `_uart`, `_img`, `_debug`.
   - Обёртка `kg_mcu`: порты `mcu.vhd` nanomig + tsconf + `FILELOAD_*` (rk86 / spec256 / alf).
   - Параметры: `ENABLE_RTC/UART/MATRIX/DEBUG/IMG/FILE/FT/SD2`, `RTC_SKIP_0D`, `RTC_SEND_LIMIT`, `FILE_CMDS`, `FILE_WR_EACH`, `FILE_TO_ROM`.
   - Коды команд — в `kg_mcu_cmds.vh`, сверены с `config.h`. `0x09` называется `CMD_CONTROL` (как в nanomig и profi).
   - Отдельного `ENABLE_PS2` нет: неподключённые выходы XST убирает сам.

   Проверка:
   - `tb_eq_mcu`: потактно против `mcu.vhd` nanomig (ISim), 29 млн сравнений, 0 ошибок.
   - `tb_kg_mcu` (iverilog, CI): функции tsconf, загрузчики rk86 / alf, фильтр CS, полная очередь.
   - `tb_mcu` / `tb_img` с `kg_mcu`.
   - nanomig с `kg_mcu`: `tb_rtc` — 0 ошибок. Тайминг выполнен на всех трёх платах:

     | Плата | LUT, было → стало | Slices | Худший slack |
     |---|---|---|---|
     | Mini G | 13 764 → 13 400 | 3 755 → 3 730 | 2,54 → 0,10 нс |
     | Mini | 13 760 → 13 470 | 99% | 2,91 нс |
     | Go | 12 475 → 12 204 | 96 → 98% | 0,37 нс |

     Худшие пути не идут через MCU. На Go это Paula (`audlen`), на Mini G — `dvi_only` → сдвиговые регистры HDMI: статический сигнал, который анализируется как путь на 5-кратный клок. Его стоит снять констрейнтой TIG или пересинхронизировать (nanomig).

   Изменения для остальных ядер (их проверять при переводе, этап 4):
   - исправления линка nanomig;
   - кадр декодируется один раз (tsconf переключал `MS_UPD` и флаги scancode дважды);
   - включение ROM-загрузчика ничего не пишет;
   - у входов нет значений по умолчанию (их надо привязать в top);
   - очередь на 512 слов.

   Находка: XST строит запись части вектора как мультиплексор по всему вектору (LUT на бит вместо CE). Поэтому в декодерах — регистр на каждое поле.
4. **Перевод ядер по одному.** На железе каждый раз проверять загрузку ROM, OSD, клавиатуру, джойстики, HDMI со звуком. Порядок:
   1. nanomig — *сделано 2026-10-18* (`kg_mcu`, остальные модули пока старые);
   2. profi — *сделано 2026-10-18, ждёт проверки на железе*. Первое ядро целиком на `kg_*`:
      - `mcu.vhd` → `kg_mcu` (`CS_FILTER(3)`, RTC, UART, MATRIX; FILE, IMG, FT, SD2 выключены);
      - `soft_switches` (две раскладки, Go и Mini) → `kg_soft_switches` и generic `SOFTSW_LAYOUT` в `profi.vhd`;
      - `cursor` → `kg_cursor`, `pix_doubler` → `kg_pix_doubler`;
      - `dpram`, `dpram2` (VRAM, OSD, буфер HDMI) → `kg_sdpram`, `sprom` → `kg_sprom`;
      - `fifo` (ZiFi) → `kg_fifo`, счётчик насыщается как у `fifo.v` (ZiFi отдаёт «свободно = 255 − занято»);
      - `pcm5102` → `kg_pcm5102`, `dac` → `kg_sigma_delta_dac`, `PLL_BASE` в `clock.vhd` → `kg_pll`;
      - HDMI (zhdmi, `hdmi_pll`, `dvi`) взят из modules как есть.

      Coregen в сборке profi не было, неиспользуемый `ipcore_dir` удалён. Удалены и `.xise`: сборка теперь через `src/Makefile`.

      | Плата | LUT, было → стало | Slices | Тайминг, было → стало |
      |---|---|---|---|
      | Go | 10 733 → 10 670 | 3 468 → 3 467 | в ucf нет констрейнтов (и не было), худший путь регистр–регистр по trce 22,6 → 21,0 нс |
      | Mini | 12 587 → 12 540 | 3 712 → 3 696 | выполнен (только `TS_CLK_MCU`: 9,27 → 9,88 нс) |
      | Mini G | 12 878 → 12 846 | 3 736 → 3 740 | 5 нарушений и до, и после, score 2,84 → 2,72 млн |

      Mini G: худшие пути до и после не идут через MCU. 16 МГц: −9,10 → −8,32 нс. `TS_SRAM_OUT`: −3,57 → −2,77, `TS_SRAM_IN`: −1,42 → −1,48. `clk_bus`: −0,74 → −3,08 нс — это переход звука из `clk_8` (SAA1099) через комбинационный микшер в `kg_pcm5102` в домене `clk_bus`; в базе такой же переход шёл в `pcm5102`. Тайминг profi правится отдельно: констрейнты для Go, регистр или TIG на переходах звука, SRAM IO.

      Тайминг profi закрыт 2026-10-19 (profi PR #9, сборка 26101901, ждёт проверки на железе), modules не менялись. Один блок констрейнтов в трёх ucf: PERIOD на CLK_50MHZ, `TS_CLK_MCU` 32 МГц, FROM-TO DATAPATHONLY на асинхронных переходах (MCU_SCK ↔ clk_bus, clk_bus ↔ clk_8 FDC), SRAM 12 + 12 нс. Все констрейнты выполнены на трёх платах и при 28, и при 24 МГц (`make <board>-ds80`). SAA1099 перенесён на clk_bus с CE 8 МГц, General Sound — на отдельный выход PLL 28 МГц, клоки из логики и защёлки заменены на CE.

      | Плата | LUT | Score с реальными констрейнтами, master (28 / 24 МГц) → после |
      |---|---|---|
      | Go | 10 670 → 10 727 | 2,47 / 2,79 млн → 0 / 0 |
      | Mini | 12 540 → 12 560 | 2,17 / 2,66 млн → 0 / 0 |
      | Mini G | 12 846 → 12 889 | 2,51 / 2,96 млн → 0 / 0 |

      Находки для остальных ядер:
      - clk_bus через BUFGMUX (28 / 24 МГц): оба PERIOD покрывают одни и те же триггеры, trce анализирует только более быстрый. Переходы на другие клоки PLL при второй частоте не проверяются (у profi GS ↔ SDRAM при 24 МГц: 5,9 нс вместо 11,85, до −5,2 нс). Нужен отдельный прогон trce с изменённым PERIOD в pcf (`<board>-ds80` в Makefile profi).
      - `kg_pll` перед BUFGMUX / BUFGCE: биты `BUFG_MASK` в 0 (иначе каскад BUFG → BUFGMUX вне выделенной трассировки, в Go стоял `CLOCK_DEDICATED_ROUTE = FALSE`). Из VHDL `BUFG_MASK` передаётся целым числом.
      - Клоки из логики и защёлки ищутся в «Clock Information» `.syr`. XST молча выбрасывает вторую ветку `elsif x'event` (у profi так терялся старший байт Nemo IDE).
      - Сети выходов PLL без BUFG называются по сигналу верхнего уровня (`U1/U1/pll_clk<0>`), а не `.../clkout<0>`: имена для TNM_NET проверять ngdbuild.
   3. tsconf — *сделано и проверено на железе 2026-10-19* (сборка 26101918). На `kg_*`: `mcu` → `kg_mcu` (PS/2, XT, UART, RTC; matrix на Mini G, burst 32 МГц на Mini G), `soft_switches`, `cursor`, `overlay` → `kg_osd_overlay`, `dpram` / `fifo` / rom → `kg_sdpram` / `kg_fifo`, `pcm5102`, `dac` → `kg_sigma_delta_dac`, `pll` → `kg_pll`, HDMI → zhdmi из modules (на Mini / Mini G около 900 LUT больше прежнего кодера, решено оставить). `.xise` удалены, сборка через `src/Makefile`. Новый модуль `kg_async_fifo`. Один блок констрейнтов в трёх ucf: PERIOD на CLK_50MHZ, `TS_CLK_MCU` 32 МГц, FROM-TO DATAPATHONLY на асинхронных переходах (MCU_SCK, clk_8 FDC, FT_CLK, ESP32 I2S), SRAM 12 + 12 нс, свой PERIOD 64 МГц на пиксельный клок FT. Все констрейнты выполнены на трёх платах, на Mini / Mini G и во втором прогоне trce для режима ядра (`make <board>-coremode`).

      | Плата | LUT master → после | Slices | Score с реальными констрейнтами, master → после |
      |---|---|---|---|
      | Go | 12 465 → 12 425 | 3 693 → 3 622 | 5,56 млн → 0 |
      | Mini | 13 313 → 14 447 | 3 710 → 3 756 | 8,30 млн → 0 |
      | Mini G | 13 424 → 14 452 | 3 756 → 3 756 | 12,80 млн → 0 |

      Находки для остальных ядер (baseconf, menu, vt100 с тем же HDMI и FT812):
      - `hdmi_pll` (FT812 на HDMI) не программировал DCM_CLKGEN: `fctl` отставал на такт, был уже, чем данные, и `-1` без размера в конкатенации занимал 32 бита. В FT-режимах пиксельный клок оставался прежним. У baseconf и menu такой же код.
      - 5x клок DCM_SP на -2 (CLKFX до 333 МГц): FT-режимы на HDMI до 64 МГц, 72 и 80 МГц вне спецификации.
      - Видео FT812 в пиксельный клок: частота та же (оба от clk_8), фаза неизвестна. Два регистра подряд склеивали биты двух пикселей, нужен `kg_async_fifo`. Вход берётся по спаду FT_CLK в IOB, запись в FIFO тоже по спаду: полпериода 80 МГц меньше трассы от IOB до LUT RAM.
      - Пиксельный клок — BUFGMUX из clk_bus и DCM. В режиме ядра он примерно на 4 нс позже BUFG clk_bus, причину trce не показывает. Переходы clk_bus → пиксель выдаются по спаду clk_bus. Собственный PERIOD на выходе DCM_CLKGEN не убирает производный, поэтому режим ядра проверяется вторым прогоном trce с pcf без FT-констрейнтов (`pcf_core.py`, как `-ds80` у profi).
      - `INST ... TNM` на BUFGMUX не поддерживается: TIG на селект через KEEP-сеть.
      - MCU_SCK на Mini G шёл через IBUF по локальной трассировке, PAR не закрывал hold (−5 нс): IBUFG + BUFG. Не-клоковые нагрузки (мультиплексор SCK FT812) берутся с выхода IBUFG.
      - BUFGCE на clk_bus (`U_BUFG` в tsconf.v) прятал соотношение clk_sys ↔ clk_bus: заменён на CE от `bus_ce.v`.
      - `audio_samplerate.v` (в `zhdmi_top.v` modules) переключает `clk_audio` раз в `prescaler + 2` тактов, а строб даёт только на фронте: частота отсчётов fs/2. tsconf его больше не использует; ядрам с `zhdmi_top` (nanomig, profi) проверить на железе.
      - Клоки из логики и защёлки: `zclk` в zports, триггеры IDE, SAA1099, /RAWREAD FDC, `palsel` / `hint_beg` (начальное значение, отличное от значения сброса). `volTable` ym2149 в «Clock Information» — ROM, артефакт отчёта XST.
      - `usb_ps2_keybuf.v` (сканкоды PS/2 через регистры RTC F0..FF, их читает Wild Commander) обнулял `keybuf_di` до записи в буфер и писал 00. Старый `mcu.vhd` переключал `KB_SCANCODE_UPD` дважды за кадр и прятал это, `kg_mcu` переключает один раз. При переходе на `kg_mcu` проверять копии этого файла в других ядрах (тест `tb_kbd_rtc` tsconf).
      - Mini: путь zhdmi 5x клок → OSERDES не сошёлся на 0,21 нс из-за размещения (без логики, 5,4 нс трассы). cost table map задаётся на плату (`MAP_T_<board>` в Makefile), у Mini 2.
   4. baseconf — *пропустить*: ядра baseconf ещё нет, то, что лежит в файловой системе (`karabas-go-core-baseconf`), пока игнорировать. Упоминания baseconf в этом плане относятся к нему же;
   5. test, pcxt, vt100 (в основном ipcore группы A);
   6. alf, alf128, nes, rk86 (исправления линка + ipcore A, B, PLL). nes — *сделано 2026-10-25, ждёт проверки на железе* (сборка 26102500). На `kg_*`: `mcu` → `kg_mcu` (файловый загрузчик `FILE_CMDS(1)`, `FILE_WR_EACH(0)` — запись по смене адреса, как в старом `mcu.vhd`; FT, SD2; `ENABLE_IMG(1)` под сейвы NES, пока без потребителя; burst 32 МГц на Mini G), `soft_switches` → `kg_soft_switches`, `pcm5102` → `kg_pcm5102`, `dac` → `kg_sigma_delta_dac` (Mini), `nes_clk` → `kg_pll`, `pllx5` → `kg_dcm`, `ram2k` / `ram8k` → `kg_spram`, `framebuffer` / `osd_vram` / `rom_font` → `kg_sdpram` (шрифт как `INIT_FILE`). Свой двухклоковый `overlay.vhd`, `pix_dobler.vhd` (по спаду) и HDMI-кодер ядра остаются. `.xise` и `ipcore_dir` удалены, сборка через `src/Makefile`, модели coregen — в `src/sim/ref/ipcore` ядра, новые пары в `sim/ipcore_eq` (`ram8k`, `framebuffer`, `rom_font` с init, `nes_clk`). Констрейнты прежние (PERIOD на двух выходах PLL, переходы clk ↔ clk_vga и MCU_SCK не анализируются); настоящие — отдельным шагом.

      | Плата | LUT было → стало | Slices | RAMB16 | Тайминг |
      |---|---|---|---|---|
      | Go | 3 946 → 4 092 | 1 468 → 1 543 | 34 → 35 | выполнен |
      | Mini | 5 085 → 5 112 | 1 802 → 1 784 | 34 → 35 | выполнен |
      | Mini G | 5 030 → 5 026 | 1 745 → 1 807 | 34 → 35 | выполнен |

      +1 RAMB16 — очередь ответов `kg_fifo` 512×24 (в старом `mcu.vhd` её не было), LUT — сам `kg_mcu` (фильтр CS, очередь, декодеры).
   7. menu (загрузчик, рисковать им в последнюю очередь) — *сделано 2026-10-20, проверено на железе Mini G* (сборка 26102001: FT812 на HDMI, звук, OSD по центру). На `kg_*`: `mcu` → `kg_mcu` (FT, burst, новый декодер `kg_mcu_esp`, `ENABLE_ESP`), `soft_switches`, `overlay` → `kg_osd_overlay` (новые параметры `ALWAYS_ON`, `H_DIV4_WIDTH`), `fifo` → `kg_fifo`, `pcm5102`, `dac` → `kg_sigma_delta_dac`, `pll` → `kg_pll`, HDMI → zhdmi и `hdmi_top` / `hdmi_pll` из tsconf. `.xise` удалены, сборка через `src/Makefile`, опции map как у tsconf. Один блок констрейнтов в трёх ucf. Тесты против старого кода: `tb_eq_overlay`, `tb_mcu_esp`, `tb_hdmi_top`.

      | Плата | LUT было → стало | Slices | Score с реальными констрейнтами, было → стало |
      |---|---|---|---|
      | Go | 593 → 567 | 253 → 206 | 0 → 0 |
      | Mini | 1 827 → 2 641 | 707 → 981 | 107 381 (режим меню 485 457) → 0 / 0 |
      | Mini G | 1 784 → 2 627 | 684 → 969 | не собран до конца → 0 / 0 |

      Mini / Mini G больше на zhdmi (как у tsconf). Находки:
      - ESP → MCU (`esp8266.vhd`): байт брался из FIFO в такт чтения, к MCU уходил предыдущий (на `OK\r\n` приходило `xx O K \r`); строб без подтверждения терял байты при полной очереди ответов (509 из 700). Теперь байт держится до ACK (`kg_mcu_esp`). UART 117,9 кбод вместо 115 200 (делитель для 40 МГц, clk_sys 40,91). CTS не срабатывал. TX FIFO 256 байт может переполниться (в firmware нет управления потоком) — не исправлено.
      - `hdmi_pll` — тот же баг `fctl`, что у tsconf; `freq_counter.vhd` не брал частоту FT, сменившуюся при `ft_sel = 0` (`prev_sel`).
      - Старые ucf: PERIOD 40 / 8 МГц при реальных 40,91 / 8,18, TIG на реальном пути `o_freq`. Комментарии PLL говорили 40 / 8 / 16 / 12 МГц.
      - `kg_osd_overlay` при /2 даёт атрибут на два такта (один пиксель OSD) раньше символа, как `overlay.vhd` nanomig. Проверить во всех ядрах с /2.
      - Mini: путь `audio_en_s` → сдвиговые регистры 5x zhdmi в режиме меню не сошёлся на 0,09 нс при MAP_T 1 (как у nanomig), MAP_T 2.
   8. spec256, sdram-test;
   9. pdp2026 (PR автору);
   10. next — *сделано 2026-10-23, ждёт проверки на железе* (сборка 26102300). На `kg_*`: `mcu` → `kg_mcu` (новый `ENABLE_FLASHBOOT`: одно слово CMD_FLASHBOOT вместо слова в каждом такте; matrix на Mini G; без burst, FT, SD2), `cursor` → `kg_cursor`, `pcm5102` → `kg_pcm5102`, `dac` → `kg_sigma_delta_dac` (Mini), `pll_midi` → `kg_dcm`, coregen-память zxnext → `kg_dist_sdpram` / `kg_dist_spram` / `kg_sdpram` (паттерны спрайтов стартуют с E3, как у coregen; пары в `sim/ipcore_eq`), HDMI → zhdmi (`rtl/hdmi/hdmi_out.v`), `hdmi_frame` и DRP-`hdmi_pll` апстрима остаются. `soft_switches` удалён (выходы не использовались, F-клавиши идут через `hid_parser`), OSD в ядре нет. `.xise` и `ipcore_dir` удалены, сборка через `src/Makefile`, `MAP_T` 2 на всех платах. Один блок констрейнтов в трёх ucf; `make <board>-modes` гоняет trce для режимов VGA (DRP перепрограммирует system_pll) и для CPU на `cpu_clk_s` (`pcf_modes.py`). Тесты против старого кода: `tb_mcu_next`, `tb_hdmi_pll`, `tb_hdmi_out`, I2S.

      Старый код (master с исправлениями компиляции: Verilog-микшер в prj Go / Mini, разрядность звука Mini) и новый с реальными констрейнтами, те же опции map / par:

      | Плата | LUT было → стало | Slices | Score было → стало | `-modes`: VGA-1 (Go: VGA-1…6), CPU на `cpu_clk_s`, ошибок было → стало |
      |---|---|---|---|---|
      | Go | 10 098 → 10 018 | 3 408 → 3 372 | 0 → 0 | 16 / 56 / 68 / 106 / 145 / 201 → 4 / 21 / 34 / 61 / 131 / 259; CPU: каскад BUFGMUX (нет) → 0 |
      | Mini | 11 407 → 12 057 | 3 612 → 3 718 | 96 → 0 | 13 → 7; 276 (hold) → 0 |
      | Mini G | 11 636 → 12 132 | 3 610 → 3 719 | 0 → 0 | 15 → 12; 302 (hold) → 0 |

      Score 0 у старого кода обманчив: `CLKFX_MD_MAX` 0,2 / 5,5 в `hdmi_pll` давали анализу 5,6 МГц для счётчика на 309 МГц и ~22 МГц для пиксельного клока. Старые ucf (сборки master: 280 571 / 141 176 / 141 708) не ограничивали CLK_CPU вовсе. Прирост LUT на Mini / Mini G — zhdmi.

      Находки:
      - старый `mcu.vhd` переключал MS_UPD дважды за кадр, `cursor.vhd` сдвигал мышь на два шага за отчёт: с `kg_mcu` мышь вдвое медленнее (по смыслу так и должно быть, на железе заметно);
      - `hdmi_pll`: делитель на 311 для 128K 50 Гц (кадр HDMI точно совпадает с кадром 128K; 311 — простое, двумя DCM_CLKGEN его не получить) работал на 309 МГц на локальной трассировке с асинхронным сбросом из домена DRP; у выходов PLL_3 (пиксельный клок, ~1100 триггеров) не было BUFG. Теперь BUFG, конвейерные сравнения, синхронизированный сброс, честные `CLKFX_MD_MAX`. Комментарий ROM апстрима («/312») неверен, делит на 311;
      - CLK_CPU шёл через каскад BUFG → BUFGMUX (+2,8 нс к CLK_28); на Go — каскад трёх BUFGMUX, PAR не мог закрыть hold режима 14 МГц. Теперь BUFGMUX берёт выход PLL, Go собирается по схеме плат с HDMI (`gen_clkbuf_0` апстрима): 7 / 14 МГц на Go теперь тоже от триггера;
      - что остаётся (схема клоков ZX Next): в режимах CPU 3,5 / 7 / 14 МГц клок `cpu_clk_s` приходит на 2,5–5,2 нс позже CLK_28, у сотен путей CLK_28 → CPU запас hold меньше (триггер может взять значение следующего такта CLK_28); в VGA-1 / VGA-2 5x-клок в 4,67 раза быстрее CLK_28, логика импульса записи SRAM не укладывается на ~1 нс; VGA-3…6 на Go (30–33 МГц) не укладываются в путях CPU 28 МГц и полутактах CLK_28_n. trce не умеет задержку производного клока (PHASE сдвигает фронт запуска, `INPUT_JITTER` на выходе PLL не учитывается);
      - старый PCM5102 менял din на нарастающем bck; i2s-slave zxnext тактировался от Pi GPIO 18 через внутренний tristate (на плате Pi нет, GPIO теперь читаются как 1); Go / Mini на master не компилировались (prj с VHDL-микшером, 16 бит в 17-битный сигнал);
      - `INPUT_JITTER` / PHASE для моделирования клока из логики не годятся, см. выше; `TNM_NET` на выходе PLL, который идёт ещё и на BUFGMUX, ngdbuild называет по сети топа (`CLK_28_pll`).
   11. next186 (асимметричная память, async FIFO).
5. **Документация.** Обновить CLAUDE.md nanomig (сейчас там «copies from profi»). Вести CHANGELOG, ставить теги `vX.Y`. Изменение портов — major-версия; совместимая обёртка живёт как минимум один major.

## 8. Риски

- **Ресурсы и тайминги.** nanomig на 96–99% slice, у Go-сборки slack 0.35 нс. После каждого переноса сравнивать LUT и slack, а `ENABLE_*` должны реально выключать логику.
- **Совместимость с firmware**: конфликт `0x09` и старые FT-команды. Проверить до этапа 3.
- **Двойная фильтрация CS.** Фильтр CS и `MCU_IO[...]` сейчас в top. После переноса в `kg_mcu_link` не фильтровать дважды.
- **Async FIFO и асимметричная память** — единственные модули, которые нельзя проверить простым сравнением с coregen. Нужны отдельные тесты и проверка на железе.

## Открытые решения

- Submodule или соседний checkout. Рекомендация: submodule.
- Префикс `kg_`. Рекомендация: да.
- Переписывать ли zhdmi на Verilog. Рекомендация: позже, отдельно, когда появятся тесты.
