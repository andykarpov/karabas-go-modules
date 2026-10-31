#!/bin/bash
# kg_mcu with Icarus Verilog (also in the CI): tb_kg_mcu.v (what mcu.vhd of nanomig does not
# have: tsconf features, the file loaders of rk86 / alf, the chip select filter, a full queue),
# tb_mcu.v / tb_img.v of run_mcu_sim.sh with kg_mcu in place of mcu.vhd, and tb_bk.v (kg_bk_ram, the
# backup RAM on the file mounter), tb_printer.v (kg_mcu_printer). Each prints
# "0 errors"; tb_eq_mcu (sim/eq) compares kg_mcu with mcu.vhd clock by clock.
set -e
cd "$(dirname "$0")"
M=$(cd ../.. && pwd)
mkdir -p ../build/kg_mcu
cd ../build/kg_mcu
K="$M/rtl/mem/kg_fifo.v $M/rtl/mem/kg_sdpram.v $M/rtl/mcu/kg_spi_slave.v $M/rtl/mcu/kg_burst_rx.v $(ls "$M"/rtl/mcu/kg_mcu*.v)"
for tb in tb_kg_mcu tb_mcu tb_img tb_bk tb_printer; do
	iverilog -g2001 -Wall -Wno-timescale -DKG_MCU -I "$M/rtl/mcu" -o $tb.vvp "$M/sim/mcu/$tb.v" $K "$M/rtl/mcu/img_sdc.v" "$M/rtl/mcu/kg_bk_ram.v" \
		2>&1 | grep -v -e 'warning: Port' -e 'warning: .* implicitly' || true
	vvp -n $tb.vvp > $tb.log
	grep -E "ERROR|$tb:" $tb.log | sed "s/^/kg_mcu: /"
	grep -q "$tb: 0 errors" $tb.log
done
