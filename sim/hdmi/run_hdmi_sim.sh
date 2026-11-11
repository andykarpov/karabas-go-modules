#!/bin/bash
# The HDMI modules of the Mini boards with the FT812 (Icarus Verilog, ghdl for the VHDL originals):
# - tb_pll_reset: pll_reset holds a long request (it fell for one clock in nine);
# - tb_eq_freq_counter: kg_freq_counter against freq_counter.vhd of tsconf and of menu (ref/);
# - tb_hdmi_ft_pll: kg_hdmi_ft_pll against hdmi_pll.v of tsconf (ref/), and the programming of
#   DCM_CLKGEN on a model of it (xilinx_models.v);
# - tb_eq_island_encoder: the island encoder of zhdmi against its original (ref/), behavioural ghdl.
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

# the island encoder: behavioural ghdl (the original renamed island_encoder_ref)
sed -e 's/entity island_encoder is/entity island_encoder_ref is/' -e 's/end island_encoder;/end island_encoder_ref;/' \
	-e 's/architecture rtl of island_encoder is/architecture rtl of island_encoder_ref is/' \
	"$M/sim/hdmi/ref/zhdmi_island_encoder.vhd" > island_encoder_ref.vhd
ghdl -a --std=93c --workdir=. island_encoder_ref.vhd "$M/rtl/video/hdmi/zhdmi_island_encoder.vhd" \
	"$M/sim/hdmi/tb_eq_island_encoder.vhd"
ghdl -e --std=93c --workdir=. tb_eq_island_encoder
ghdl -r --std=93c --workdir=. tb_eq_island_encoder > tb_eq_island_encoder.log 2>&1
result tb_eq_island_encoder
