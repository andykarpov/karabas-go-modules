#!/bin/bash
# pcm5102.v and kg_pcm5102.v (tb_pcm5102.v, the I2S stream), audio_peaks.v (tb_audio_peaks.v), kg_tape_monitor (tb_kg_tape_monitor.v),
# kg_midi_tx.v (tb_midi_tx.v, the 31250 baud line), kg_ym2149 (tb_ay_verify.v, tb_ay_diff.v, below), Icarus Verilog. Each prints "0 errors".
set -e
cd "$(dirname "$0")"
M=$(cd ../.. && pwd)
mkdir -p ../build/audio
cd ../build/audio
# kg_pcm5102: the same testbench, strict
iverilog -g2001 -Wall -Wno-timescale -DKG_PCM5102 -o tb_kg_pcm5102.vvp "$M/sim/audio/tb_pcm5102.v" "$M/rtl/audio/kg_pcm5102.v"
vvp -n tb_kg_pcm5102.vvp > tb_kg_pcm5102.log
grep -E "ERROR|tb_pcm5102:" tb_kg_pcm5102.log | sed 's/^/kg_pcm5102: /'
grep -q "tb_pcm5102: 0 errors" tb_kg_pcm5102.log
for m in pcm5102 audio_peaks; do
	tb=tb_$m
	iverilog -g2001 -Wall -Wno-timescale -o $tb.vvp "$M/sim/audio/$tb.v" "$M/rtl/audio/$m.v"
	vvp -n $tb.vvp > $tb.log
	grep -E "ERROR|$tb:" $tb.log
	grep -q "$tb: 0 errors" $tb.log
done
iverilog -g2001 -Wall -Wno-timescale -o tb_midi_tx.vvp "$M/sim/audio/tb_midi_tx.v" "$M/rtl/audio/kg_midi_tx.v" "$M/rtl/mem/kg_fifo.v"
vvp -n tb_midi_tx.vvp > tb_midi_tx.log
grep -E "ERROR|tb_midi_tx:" tb_midi_tx.log
grep -q "tb_midi_tx: 0 errors" tb_midi_tx.log
iverilog -g2001 -Wall -Wno-timescale -o tb_kg_tape_monitor.vvp "$M/sim/audio/tb_kg_tape_monitor.v" "$M/rtl/audio/kg_tape_monitor.v"
vvp -n tb_kg_tape_monitor.vvp > tb_kg_tape_monitor.log
grep -E "ERROR|tb_kg_tape_monitor:" tb_kg_tape_monitor.log
grep -q "tb_kg_tape_monitor: 0 errors" tb_kg_tape_monitor.log
# kg_ym2149 / ay38910_silicon: tb_ay_verify.v (the checks of its author), tb_ay_diff.v against
# ay_model.v of lvd2 / deathsoft (GPL v3, fetched at a fixed commit, the trireg nets turned into
# keepers by lvd2_keeper.py; about 15 s, +n=<writes> for a longer run, 300 by default)
LVD2_REV=cf8d14db0aec5ae86ed4f4e6e67bf14c40a42d77
if [ ! -f lvd2/rtl/ay_model.v ]; then
	rm -rf lvd2.tmp
	git init -q lvd2.tmp
	git -C lvd2.tmp fetch -q --depth 1 https://github.com/lvd2/ay-3-8910_reverse_engineered.git $LVD2_REV
	git -C lvd2.tmp checkout -q FETCH_HEAD
	mv lvd2.tmp lvd2
fi
python3 "$M/sim/audio/lvd2_keeper.py" lvd2/rtl/ay_model.v ay_model_keeper.v
iverilog -g2001 -Wall -Wno-timescale -o tb_ay_verify.vvp "$M/sim/audio/tb_ay_verify.v" "$M/rtl/audio/ay38910_silicon.v"
vvp -n tb_ay_verify.vvp > tb_ay_verify.log
grep -E "FAIL|tb_ay_verify:" tb_ay_verify.log
grep -q "tb_ay_verify: 0 errors" tb_ay_verify.log
# the model is not Verilog-2001 clean (begin / end around generate): no -Wall for it
iverilog -g2001 -Wno-timescale -o tb_ay_diff.vvp "$M/sim/audio/tb_ay_diff.v" "$M/rtl/audio/kg_ym2149.v" \
	"$M/rtl/audio/ay38910_silicon.v" ay_model_keeper.v
vvp -n tb_ay_diff.vvp > tb_ay_diff.log
grep -E "ERROR|tb_ay_diff:" tb_ay_diff.log | head -25
grep -q "tb_ay_diff: 0 errors" tb_ay_diff.log
