#!/usr/bin/env python3
"""Init files and Verilog wrappers for run_ipcore_eq.sh (run in the build directory).

Usage: gen_models.py <karabas-go directory with the sibling cores>

- font.mif / font.hex: the rk86 font ROM (.mif for the coregen model, .hex for kg_sprom);
- rom_font.mif / rom_font.hex: the nes osd font (the init of the rom_font RAM, .hex for kg_sdpram);
- keyjoy_sdpram_64_6.mif / keyjoy.hex: the next keyjoy distributed RAM;
- e3.hex: 16K bytes E3, the start of the sprite patterns of next (sdpbram_16k_8 has the default
  data E3, the transparent index);
- <core>_ver.v: Verilog wrappers of the next dist_mem_gen / blk_mem_gen cores (ISE has the VHDL
  model only as a Verilog DIST_MEM_GEN_V7_2 / BLK_MEM_GEN_V7_3), with the generics of their .vhd.

The next and nes cores keep their coregen models in src/sim/ref/ipcore since they dropped ipcore_dir.
"""
import os
import re
import sys

K = sys.argv[1]
NEXT = K + "/karabas-go-core-next/src/sim/ref/ipcore/"
if not os.path.isdir(NEXT):
    NEXT = K + "/karabas-go-core-next/src/ipcore_dir/"
NES = K + "/karabas-go-core-nes/src/sim/ref/ipcore/"
if not os.path.isdir(NES):
    NES = K + "/karabas-go-core-nes/src/ipcore_dir/"

coe = open(K + "/karabas-go-core-rk86/src/roms/FONT.coe").read()
vec = coe.split("=", 2)[2]
vals = [int(x, 16) for x in re.split(r"[\s,;]+", vec) if x]
open("font.mif", "w").write("".join("{:08b}\n".format(x) for x in vals))
open("font.hex", "w").write("".join("%02x\n" % x for x in vals))

mif = [l.strip() for l in open(NES + "rom_font.mif") if l.strip()]
open("rom_font.mif", "w").write("\n".join(mif) + "\n")
open("rom_font.hex", "w").write("".join("%02x\n" % int(x, 2) for x in mif))

mif = [l.strip() for l in open(NEXT + "keyjoy_sdpram_64_6.mif") if l.strip()]
open("keyjoy_sdpram_64_6.mif", "w").write("\n".join(mif) + "\n")
open("keyjoy.hex", "w").write("".join("%02x\n" % int(x, 2) for x in mif))
open("e3.hex", "w").write("e3\n" * 16384)

DIST = "a,d,dpra,clk,we,dpo"
for name, ports in [("keyjoy_sdpram_64_6", DIST), ("spram_320_9", "a,d,clk,we,spo"), ("sdpram_128_8", DIST),
                    ("sdpram_16_9", DIST), ("sdpram_64_9", DIST),
                    ("sdpbram_16k_8", "clka,wea,addra,dina,clkb,enb,addrb,doutb")]:
    v = open(NEXT + name + ".vhd").read()
    gen = {}
    for k, val in re.findall(r"(c_[a-z_]+)\s*=>\s*([^,\)\n]+)", v):
        gen.setdefault(k, val.strip())
    blk = "c_addra_width" in gen
    aw = gen["c_addra_width"] if blk else gen["c_addr_width"]
    dw = gen["c_write_width_a"] if blk else gen["c_width"]
    decl = {"a": "input [%s-1:0] a;" % aw, "dpra": "input [%s-1:0] dpra;" % aw, "d": "input [%s-1:0] d;" % dw,
            "clk": "input clk;", "we": "input we;", "dpo": "output [%s-1:0] dpo;" % dw,
            "spo": "output [%s-1:0] spo;" % dw,
            "clka": "input clka;", "wea": "input [0:0] wea;", "addra": "input [%s-1:0] addra;" % aw,
            "dina": "input [%s-1:0] dina;" % dw, "clkb": "input clkb;", "enb": "input enb;",
            "addrb": "input [%s-1:0] addrb;" % aw, "doutb": "output [%s-1:0] doutb;" % dw}
    ps = ports.split(",")
    out = ["module %s(%s);" % (name, ports)] + [decl[p] for p in ps]
    out.append("%s #(\n  %s\n) inst (%s);" % ("BLK_MEM_GEN_V7_3" if blk else "DIST_MEM_GEN_V7_2",
        ",\n  ".join(".%s(%s)" % (k.upper(), val) for k, val in gen.items()),
        ", ".join(".%s(%s)" % (p.upper(), p) for p in ps)))
    out.append("endmodule")
    open(name + "_ver.v", "w").write("\n".join(out) + "\n")
