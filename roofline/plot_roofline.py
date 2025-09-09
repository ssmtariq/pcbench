#!/usr/bin/env python3
import csv
import math
import sys
from pathlib import Path
import matplotlib.pyplot as plt

def read_summary(csv_path):
    out = {}
    with open(csv_path, newline='') as f:
        for row in csv.DictReader(f):
            k = row['metric'].strip()
            v = row['value'].strip()
            out[k] = float(v) if v not in ("", None) else None
    return out

def bytes_per_sec(mbytes_per_s):
    return None if mbytes_per_s is None else mbytes_per_s * 1024 * 1024

def plot_roofline(csv_path, title=None, savepath=None):
    d = read_summary(csv_path)

    # App point: Instr/s and Instr/Byte (x,y)
    app_x = d.get('app_instr_per_byte')
    app_instr_per_s = d.get('app_instr_per_sec')
    if app_x is None or app_instr_per_s is None:
        raise RuntimeError("Missing app point (app_instr_per_byte or app_instr_per_sec) in CSV")

    # Roofs (bandwidth in MBytes/s)
    roofs = []
    for name in ['roof_L1','roof_L2','roof_L3','roof_MEM']:
        v = d.get(name)
        if v is not None and v > 0:
            roofs.append((name.split('_',1)[1], bytes_per_sec(v)))

    if not roofs:
        raise RuntimeError("No roofs found in CSV (roof_L1/roof_L2/roof_L3/roof_MEM)")

    # X domain: cover app point and reasonable margin
    # On an Instruction Roofline, performance = min_i (x * B_i) and optionally a compute roof (not drawn here).
    # We just draw the four slanted roofs.
    x_min = max(1e-6, app_x / 10.0)
    x_max = app_x * 10.0

    xs = [x_min * (10 ** (i/100 * math.log10(x_max/x_min))) for i in range(101)]  # log-spaced

    plt.figure()
    for label, B in roofs:
        ys = [x * B for x in xs]
        plt.loglog(xs, ys, label=f"{label} roof")

    # Plot app point
    plt.loglog([app_x], [app_instr_per_s], marker='o', linestyle='None', label="PostgreSQL (tpcc)")

    plt.xlabel("Operational intensity (Instructions / Byte)")
    plt.ylabel("Performance (Instructions / second)")
    plt.title(title or "Instruction Roofline (PostgreSQL + BenchBase)")
    plt.legend()
    plt.grid(True, which='both', ls=':')

    if savepath:
        plt.savefig(savepath, bbox_inches='tight', dpi=150)
    else:
        plt.show()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 plot_roofline.py /path/to/roofline_summary.csv [output.png]")
        sys.exit(1)
    csv_path = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) >= 3 else None
    plot_roofline(str(csv_path), title=None, savepath=str(out) if out else None)
