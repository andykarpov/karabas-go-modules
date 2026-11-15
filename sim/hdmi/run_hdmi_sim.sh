#!/bin/bash
# The HDMI modules of the Mini boards with the FT812 (Icarus Verilog, ghdl for the VHDL originals):
# - tb_pll_reset: pll_reset holds a long request (it fell for one clock in nine);
# - tb_eq_freq_counter: kg_freq_counter against freq_counter.vhd of tsconf and of menu (ref/);
# - tb_hdmi_ft_pll: kg_hdmi_ft_pll against hdmi_pll.v of tsconf (ref/), and the programming of
#   DCM_CLKGEN on a model of it (xilinx_models.v);
# - tb_eq_island_encoder: the island encoder of zhdmi against its original (ref/), behavioural ghdl;
# - tb_hdmi_tx_outreg: hdmi_tx with OUTPUT_REG = 1 against OUTPUT_REG = 0, the serial outputs one pixel
#   later; hdmi_tx as ghdl --synth netlists (dvi.vhd is VHDL-2008 and zhdmi_packet_gen.vhd VHDL-93,
#   so the copy of zhdmi_tx.vhd takes dvi as a component and dvi is a netlist of its own).
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

# hdmi_tx with OUTPUT_REG 0 / 1: two netlists, the modules of the second renamed *_r1
H="$M/rtl/video/hdmi"
mkdir -p w93 w08
python3 - "$H/zhdmi_tx.vhd" zhdmi_tx_sim.vhd <<'PY'
import re, sys
s = open(sys.argv[1]).read()
comp = ("\tcomponent dvi port (CLK, RESET : in std_logic; RGB : in std_logic_vector(23 downto 0);\n"
	"\t\tHSYNC, VSYNC, DE : in std_logic; ENC_RED, ENC_GREEN, ENC_BLUE : out std_logic_vector(9 downto 0));\n"
	"\tend component;\n")
s, n1 = re.subn(r"(architecture rtl of hdmi_tx is\n)", lambda m: m.group(1) + comp, s)
s, n2 = re.subn(r"\bdvi: entity work\.dvi port map\(", "dvi_inst: dvi port map(", s)
assert n1 == 1 and n2 == 1, "zhdmi_tx.vhd changed: update run_hdmi_sim.sh"
open(sys.argv[2], "w").write(s)
PY
ghdl -a --std=93c --workdir=w93 --work=unisim "$M/sim/lint/unisim_stubs.vhd"
for R in 0 1; do
	ghdl --synth --std=93c --ieee=synopsys --workdir=w93 -Pw93 --out=verilog -gSAMPLE_FREQ=48000 -gOUTPUT_REG=$R \
		"$H/zhdmi_tmds_encoder.vhd" "$H/zhdmi_tmds_serializer_spartan6.vhd" "$H/zhdmi_audio_packetizer.vhd" \
		"$H/zhdmi_island_encoder.vhd" "$H/zhdmi_packet_gen.vhd" "$H/zhdmi_signaling.vhd" zhdmi_tx_sim.vhd \
		-e hdmi_tx > hdmi_tx_or$R.v 2> ghdl_or$R.log || { cat ghdl_or$R.log; exit 1; }
done
python3 - hdmi_tx_or1.v <<'PY'
import re, sys
s = open(sys.argv[1]).read()
for m in re.findall(r"^module (\w+)", s, re.M):
	s = re.sub(r"\b%s\b" % m, m + "_r1", s)
open(sys.argv[1], "w").write(s)
PY
ghdl --synth --std=08 --ieee=synopsys --workdir=w08 --out=verilog "$H/dvi_encoder.vhd" "$H/dvi.vhd" -e dvi \
	> dvi_vhdl.v 2> ghdl_dvi.log || { cat ghdl_dvi.log; exit 1; }
iverilog -g2005 -o tb_hdmi_tx_outreg.vvp "$M/sim/hdmi/tb_hdmi_tx_outreg.v" hdmi_tx_or0.v hdmi_tx_or1.v dvi_vhdl.v \
	2> iverilog_or.log || { cat iverilog_or.log; exit 1; }
vvp -n tb_hdmi_tx_outreg.vvp > tb_hdmi_tx_outreg.log
result tb_hdmi_tx_outreg
