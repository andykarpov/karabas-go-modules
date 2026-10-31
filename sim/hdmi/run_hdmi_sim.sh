#!/bin/bash
# The HDMI modules of the Mini boards with the FT812 (Icarus Verilog, ghdl for the VHDL originals):
# - tb_pll_reset: pll_reset holds a long request (it fell for one clock in nine);
# - tb_eq_freq_counter: kg_freq_counter against freq_counter.vhd of tsconf and of menu (ref/);
# - tb_hdmi_ft_pll: kg_hdmi_ft_pll against hdmi_pll.v of tsconf (ref/), and the programming of
#   DCM_CLKGEN on a model of it (xilinx_models.v).
# Each prints "<tb>: 0 errors".
set -e
cd "$(dirname "$0")"
M=$(cd ../.. && pwd)
mkdir -p ../build/hdmi
cd ../build/hdmi

result() {
	grep -E "ERROR|$1:" $1.log | head -30
	grep -q "$1: 0 errors" $1.log
}
IV="iverilog -g2001 -Wall -Wno-timescale -Wno-implicit-dimensions -I $M/sim/eq"

for c in tsconf menu; do
	ghdl --synth --std=08 -fexplicit --ieee=synopsys --out=verilog "$M/sim/hdmi/ref/${c}_freq_counter.vhd" \
		-e freq_counter 2> /dev/null | sed "s/^module freq_counter\b/module freq_counter_$c/" > freq_counter_$c.v
done
sed -e 's/^module hdmi_pll(/module tsconf_hdmi_pll(/' -e 's/^freq_counter freq_counter_inst/freq_counter_tsconf freq_counter_inst/' \
	-e '/`default_nettype none/d' "$M/sim/hdmi/ref/tsconf_hdmi_pll.v" > tsconf_hdmi_pll.v

$IV -o tb_pll_reset.vvp "$M/sim/hdmi/tb_pll_reset.v" "$M/rtl/video/hdmi/pll_reset.v"
vvp -n tb_pll_reset.vvp > tb_pll_reset.log
result tb_pll_reset

$IV -o tb_eq_freq_counter.vvp "$M/sim/hdmi/tb_eq_freq_counter.v" freq_counter_tsconf.v freq_counter_menu.v \
	"$M/rtl/video/hdmi/kg_freq_counter.v"
vvp -n tb_eq_freq_counter.vvp > tb_eq_freq_counter.log
result tb_eq_freq_counter

$IV -o tb_hdmi_ft_pll.vvp "$M/sim/hdmi/tb_hdmi_ft_pll.v" "$M/sim/hdmi/xilinx_models.v" tsconf_hdmi_pll.v \
	freq_counter_tsconf.v "$M/rtl/video/hdmi/pll_reset.v" "$M/rtl/video/hdmi/kg_freq_counter.v" \
	"$M/rtl/video/hdmi/kg_hdmi_ft_pll.v"
vvp -n tb_hdmi_ft_pll.vvp > tb_hdmi_ft_pll.log
result tb_hdmi_ft_pll
