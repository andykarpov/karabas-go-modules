#!/bin/bash
# pcm5102.v and kg_pcm5102.v (tb_pcm5102.v, the I2S stream), audio_peaks.v (tb_audio_peaks.v) and
# kg_midi_tx.v (tb_midi_tx.v, the 31250 baud line), Icarus Verilog. Each prints "0 errors".
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
