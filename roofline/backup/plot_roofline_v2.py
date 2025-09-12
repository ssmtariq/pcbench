#!/usr/bin/env python3
import csv, math, sys
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

def to_bytes_per_sec(mbytes_per_s):
    return None if mbytes_per_s is None else mbytes_per_s * 1024 * 1024

def logspace(x0, x1, n=256):
    # inclusive log space
    return [10.0 ** (math.log10(x0) + i*(math.log10(x1/x0)/(n-1))) for i in range(n)]

def plot_roofline(csv_path, title=None, savepath=None):
    d = read_summary(csv_path)

    # App point
    app_x = d.get('app_instr_per_byte')
    app_y = d.get('app_instr_per_sec')
    if app_x is None or app_y is None:
        raise RuntimeError("Missing app point (app_instr_per_byte or app_instr_per_sec) in CSV")

    # Bandwidth roofs (bytes/s)
    roofs = []
    for name in ('roof_L1','roof_L2','roof_L3','roof_MEM'):
        v = d.get(name)
        if v is not None and v > 0:
            roofs.append((name.split('_',1)[1], to_bytes_per_sec(v)))

    if not roofs:
        raise RuntimeError("No roofs in CSV (roof_L1/roof_L2/roof_L3/roof_MEM)")

    # Optional compute ceiling
    compute = d.get('roof_compute_instr_per_sec_est')
    knees = []
    if compute and compute > 0:
        for _, B in roofs:
            knees.append(compute / B)

    # X-range: cover app point and the knees (if any)
    x_candidates = [app_x]
    if knees:
        x_candidates += knees
    x_min = max(1e-3, min(x_candidates) / 10.0)
    x_max = max(app_x * 10.0, (max(knees) * 10.0 if knees else app_x * 10.0))
    xs = logspace(x_min, x_max, n=256)

    plt.figure(figsize=(7.2, 5.4))

    # Draw clipped roofs (each slanted line capped at compute, if present)
    for label, B in sorted(roofs, key=lambda t: t[1]):  # sort by bandwidth
        ys = [x * B for x in xs]
        if compute and compute > 0:
            ys = [min(y, compute) for y in ys]
        plt.loglog(xs, ys, linewidth=2, label=f"{label} roof")

    # Draw compute roof only from the first knee to the end
    if compute and compute > 0 and knees:
        start = min(knees)
        xs2 = [x for x in xs if x >= start]
        if xs2:
            plt.loglog(xs2, [compute]*len(xs2), linestyle='--', linewidth=2,
                       label="Compute roof (instr/s est)")

    # App point
    plt.loglog([app_x], [app_y], marker='o', markersize=8,
               linestyle='None', label="PostgreSQL (tpcc)")

    plt.xlabel("Operational intensity (Instructions / Byte)")
    plt.ylabel("Performance (Instructions / second)")
    plt.title(title or "Instruction Roofline (PostgreSQL + BenchBase)")
    plt.grid(True, which='both', ls=':')
    plt.legend(loc='best')
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
