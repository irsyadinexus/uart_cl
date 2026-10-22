#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# Summarise the functional-coverage bins (SVA cover points from uart_fcov.sv)
# recorded in a Verilator coverage.dat file.
#
#   usage: python3 scripts/fcov_report.py [coverage.dat]
# ---------------------------------------------------------------------------
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "coverage.dat"
try:
    data = open(path, "rb").read().decode("latin1")
except FileNotFoundError:
    sys.exit(f"{path} not found -- run 'make coverage' first")

bins = {}
for line in data.splitlines():
    if "v_user/uart_fcov" not in line:
        continue
    m = re.search(r"(\d+)\s*$", line)
    if not m:
        continue
    name = dict(re.findall("\x01([a-z])\x02([^\x01]*)", line)).get("o", "?")
    bins[name] = bins.get(name, 0) + int(m.group(1))

groups = [
    ("Frame configurations (data x parity x stop)", "cp_d"),
    ("Received data patterns",                      "cp_rx"),
    ("Error events",                                "cp_err"),
]

total_hit = total = 0
for title, prefix in groups:
    sub = {k: v for k, v in bins.items() if k.startswith(prefix)}
    hit = sum(1 for v in sub.values() if v > 0)
    total_hit += hit
    total += len(sub)
    print(f"\n{title}: {hit}/{len(sub)} covered")
    for k in sorted(sub):
        mark = "OK  " if sub[k] > 0 else "MISS"
        print(f"   [{mark}] {k:16} {sub[k]:5} hits")

print(f"\nFUNCTIONAL COVERAGE: {total_hit}/{total} bins "
      f"({100*total_hit/total:.0f}%)" if total else "no bins found")
sys.exit(0 if total and total_hit == total else 1)
