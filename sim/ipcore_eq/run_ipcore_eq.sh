#!/bin/bash
# The kg_* replacements of the coregen cores against the cores themselves (ISim, ISE 14.7):
# tb_mem.v (block / distributed memories) and tb_clk.v (PLL, DCM). Both print "0 errors".
# Needs the sibling cores karabas-go-core-{nes,alf,pdp2026,next186,rk86,next} next to this
# repository (their ipcore_dir models and init files; nes and next keep them in src/sim/ref/ipcore). Add a pair here when a core moves from a
# coregen core to a kg_* module.
set -e
source /opt/Xilinx/14.7/ISE_DS/settings64.sh > /dev/null
cd "$(dirname "$0")"
HERE=$(pwd)
M=$(cd ../.. && pwd)
K=$(cd ../../.. && pwd)
CORELIB=$XILINX/verilog/src/XilinxCoreLib
# the coregen models of next: src/sim/ref/ipcore since it dropped ipcore_dir (as gen_models.py)
NEXT=$K/karabas-go-core-next/src/sim/ref/ipcore
[ -d "$NEXT" ] || NEXT=$K/karabas-go-core-next/src/ipcore_dir
NES=$K/karabas-go-core-nes/src/sim/ref/ipcore
[ -d "$NES" ] || NES=$K/karabas-go-core-nes/src/ipcore_dir
mkdir -p ../build/ipcore_eq
cd ../build/ipcore_eq
python3 -I "$HERE/gen_models.py" "$K"

cat > mem.prj <<PRJ
verilog work "$CORELIB/BLK_MEM_GEN_V7_3.v"
verilog work "$CORELIB/DIST_MEM_GEN_V7_2.v"
verilog work "$NES/ram2k.v"
verilog work "$NES/ram8k.v"
verilog work "$NES/framebuffer.v"
verilog work "$NES/rom_font.v"
verilog work "$K/karabas-go-core-alf/src/ipcore_dir/osd_vram.v"
verilog work "$K/karabas-go-core-pdp2026/ipcore_dir/sectorbuf.v"
verilog work "$K/karabas-go-core-next186/src/ipcore_dir/cache.v"
verilog work "$K/karabas-go-core-rk86/src/ipcore_dir/font/font.v"
verilog work "keyjoy_sdpram_64_6_ver.v"
verilog work "spram_320_9_ver.v"
verilog work "sdpram_128_8_ver.v"
verilog work "sdpram_16_9_ver.v"
verilog work "sdpram_64_9_ver.v"
verilog work "sdpbram_16k_8_ver.v"
verilog work "$M/rtl/mem/kg_spram.v"
verilog work "$M/rtl/mem/kg_sprom.v"
verilog work "$M/rtl/mem/kg_sdpram.v"
verilog work "$M/rtl/mem/kg_tdpram.v"
verilog work "$M/rtl/mem/kg_dist_sdpram.v"
verilog work "$M/rtl/mem/kg_dist_spram.v"
verilog work "$HERE/tb_mem.v"
PRJ

cat > clk.prj <<PRJ
verilog work "$K/karabas-go-core-alf/src/ipcore_dir/pll.v"
verilog work "$K/karabas-go-core-alf/src/ipcore_dir/pllx5.v"
verilog work "$NES/nes_clk.v"
vhdl work "$NEXT/pll_midi.vhd"
verilog work "$M/rtl/clk/kg_pll.v"
verilog work "$M/rtl/clk/kg_dcm.v"
verilog work "$HERE/tb_clk.v"
verilog work "$XILINX/verilog/src/glbl.v"
PRJ

echo "run all; quit" > run.tcl
fuse -prj mem.prj -L unisims_ver -top work.tb_mem -o tb_mem.exe > fuse_mem.log || { grep ERROR fuse_mem.log; exit 1; }
./tb_mem.exe -tclbatch run.tcl > sim_mem.log
fuse -prj clk.prj -L unisims_ver -top work.tb_clk -top work.glbl -o tb_clk.exe > fuse_clk.log || { grep ERROR fuse_clk.log; exit 1; }
./tb_clk.exe -tclbatch run.tcl > sim_clk.log
grep -E "coregen .* kg|^tb_" sim_mem.log sim_clk.log | head -40
grep -q "tb_mem: .* 0 errors" sim_mem.log
grep -q "tb_clk: .* 0 errors" sim_clk.log
