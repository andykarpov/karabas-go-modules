#!/usr/bin/env python3
# lvd2_keeper.py <ay_model.v> <out.v>: ay_model.v of lvd2 (github.com/lvd2/ay-3-8910_reverse_engineered)
# for iverilog, which has no trireg (charge storage nets: the pass gates and latches of the chip).
# Each trireg becomes a wire with a weak keeper of its last value: any driver overrides it, without
# one the net keeps what it had, as a trireg. Nothing else of the model changes.
import re
import sys

src = open(sys.argv[1]).read()


def rep(m):
    ind, rng, names, tail = m.group(1), m.group(2) or '', m.group(3), m.group(4)
    out = []
    for n in [x.strip() for x in names.split(',')]:
        out.append(f"{ind}wire {rng}{n}; reg {rng}{n}_keep; // karabas: trireg = a weak keeper of the last value\n"
                   f"{ind}assign (weak1, weak0) {n} = {n}_keep;\n"
                   f"{ind}always @({n}) {n}_keep = {n};{tail}")
    return '\n'.join(out)


out, n = re.subn(r'^([ \t]*)trireg[ \t]+(\[[^\]]+\][ \t]*)?([\w, \t]+?);([^\n]*)$', rep, src, flags=re.M)
if n != 6 or re.search(r'^\s*trireg\b', out, flags=re.M):
    sys.exit(f"lvd2_keeper.py: {n} trireg declarations replaced, 6 expected (another version of ay_model.v?)")
open(sys.argv[2], 'w').write(out)
