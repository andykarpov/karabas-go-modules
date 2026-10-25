#!/bin/bash
# All tests of this repository.
# - always (the CI runs these): lint, memories, audio, kg_sync, kg_mcu, the kg_* ports against the VHDL
#   they replace (verilator, Icarus Verilog, ghdl);
# - with ISE 14.7 in /opt/Xilinx/14.7: also the ports of spi_slave and overlay, the MCU link (ISim),
#   and the coregen equivalence when the sibling core repositories are there.
cd "$(dirname "$0")"
fail=0
run() {
	echo "==== $1"
	./$1 || { echo "==== $1 FAILED"; fail=1; }
}
run lint/run_lint.sh
run mem/run_mem_sim.sh
run audio/run_audio_sim.sh
run ctl/run_ctl_sim.sh
run mcu/run_kg_mcu_sim.sh
if [ -f /opt/Xilinx/14.7/ISE_DS/settings64.sh ]; then
	run eq/run_eq.sh
	run mcu/run_mcu_sim.sh
	if [ -d ../../karabas-go-core-next186 ]; then run ipcore_eq/run_ipcore_eq.sh; else echo "==== ipcore_eq: no sibling cores, skipped"; fi
else
	run "eq/run_eq.sh --no-isim"
	echo "==== no ISE: eq of spi_slave, overlay and mcu, run_mcu_sim, ipcore_eq skipped"
fi
[ $fail = 0 ] && echo "==== all passed" || { echo "==== FAILED"; exit 1; }
