#!/bin/bash
# kg_mcu2 (MCU link v2) with Icarus Verilog (also in the CI): tb_kg_mcu2.v, a model of the mcu,
# at 16 and 32 MHz sck, with the bytes back to back (a DMA transfer) and with gaps between them,
# the core clock at 28 MHz, plus 32 MHz sck with a 12.5 MHz core clock. Each prints "0 errors".
set -e
cd "$(dirname "$0")"
M=$(cd ../.. && pwd)
mkdir -p ../build/kg_mcu2
cd ../build/kg_mcu2
K="$M/rtl/mcu/kg_mcu2.v $M/rtl/mcu/kg_l2_link.v $M/rtl/mcu/kg_l2_sys.v $M/rtl/mcu/kg_l2_hid.v $M/rtl/mcu/kg_l2_load.v $M/rtl/mcu/kg_l2_osd.v $M/rtl/mcu/kg_l2_img.v $M/rtl/mcu/kg_l2_port.v"
for cfg in "31 0 17.86" "16 0 17.86" "31 300 17.86" "16 300 17.86" "16 0 40"; do
	set -- $cfg
	iverilog -g2001 -Wall -Wno-timescale -Ptb_kg_mcu2.SCK_HALF=$1 -Ptb_kg_mcu2.GAP=$2 -Ptb_kg_mcu2.CLK_HALF=$3 \
		-o tb_kg_mcu2.vvp "$M/sim/mcu/tb_kg_mcu2.v" $K 2>&1 | grep -v -e 'warning: Port' -e 'warning: .* implicitly' || true
	vvp -n tb_kg_mcu2.vvp > tb_kg_mcu2.log
	grep -E "ERROR|tb_kg_mcu2:" tb_kg_mcu2.log | sed "s/^/kg_mcu2: /"
	grep -q "tb_kg_mcu2: 0 errors" tb_kg_mcu2.log
done

# the file mounter: kg_mcu2 target 03 (kg_l2_img) against a model of a drive (sdc_*)
iverilog -g2001 -Wall -Wno-timescale -o tb_kg_l2_img.vvp "$M/sim/mcu/tb_kg_l2_img.v" $K 2>&1 | grep -v -e 'warning: Port' -e 'warning: .* implicitly' || true
vvp -n tb_kg_l2_img.vvp > tb_kg_l2_img.log
grep -E "ERROR|tb_kg_l2_img:" tb_kg_l2_img.log | sed "s/^/kg_l2_img: /"
grep -q "tb_kg_l2_img: 0 errors" tb_kg_l2_img.log

# the byte streams: kg_mcu2 target 05 (kg_l2_port), all four ports
iverilog -g2001 -Wall -Wno-timescale -o tb_kg_l2_port.vvp "$M/sim/mcu/tb_kg_l2_port.v" $K 2>&1 | grep -v -e 'warning: Port' -e 'warning: .* implicitly' || true
vvp -n tb_kg_l2_port.vvp > tb_kg_l2_port.log
grep -E "ERROR|tb_kg_l2_port:" tb_kg_l2_port.log | sed "s/^/kg_l2_port: /"
grep -q "tb_kg_l2_port: 0 errors" tb_kg_l2_port.log

# the bitmap OSD: kg_mcu2 target 02 + kg_l2_osd_overlay over an 800 x 600 picture (about a minute)
iverilog -g2001 -Wall -Wno-timescale -o tb_kg_l2_osd.vvp "$M/sim/video/tb_kg_l2_osd.v" $K \
	"$M/rtl/video/osd/kg_l2_osd_overlay.v" "$M/rtl/mem/kg_sdpram.v" 2>&1 | grep -v -e 'warning: Port' -e 'warning: .* implicitly' || true
vvp -n tb_kg_l2_osd.vvp > tb_kg_l2_osd.log
grep -E "ERROR|tb_kg_l2_osd:" tb_kg_l2_osd.log | sed "s/^/kg_l2_osd: /"
grep -q "tb_kg_l2_osd: 0 errors" tb_kg_l2_osd.log
