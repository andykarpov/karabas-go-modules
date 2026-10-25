#!/bin/bash
# The modules of rtl/ctl without a VHDL original: kg_sync (tb_sync.v), Icarus Verilog. Prints
# "tb_sync: ... 0 errors". (kg_soft_switches is checked against soft_switches.vhd in sim/eq.)
set -e
cd "$(dirname "$0")"
M=$(cd ../.. && pwd)
mkdir -p ../build/ctl
cd ../build/ctl
iverilog -g2001 -Wall -Wno-timescale -o tb_sync.vvp "$M/sim/ctl/tb_sync.v" "$M/rtl/ctl/kg_sync.v"
vvp -n tb_sync.vvp > sync.log
grep -E "ERROR|errors|expected" sync.log | head
grep -q "tb_sync: .* 0 errors" sync.log
