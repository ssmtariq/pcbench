#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import csv, math, sys
from pathlib import Path
import matplotlib.pyplot as plt

# ---------- helpers ----------
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

def mid_before_knee(xs, knee):
    # choose an x to place text on the sloped part
    x = xs[len(xs)//3]
    if knee is not None:
        x = min(0.7 * knee, x)
    return x

# ---------- main plot ----------
def plot_roofline(csv_path, title=None, savepath=None):
    d = read_summary(csv_path)

    # App point
    app_x = d.get('app_instr_per_byte')
    app_y = d.get('app_instr_per_sec')
    if app_x is None or app_y is None:
        raise RuntimeError("Missing app point (app_instr_per_byte or app_instr_per_sec) in CSV")

    # Bandwidth roofs (Bytes/s)
    # We’ll draw in order: MEM, L3, L2, L1 (low->high bandwidth gives nicer layering)
    order = ('roof_MEM', 'roof_L3', 'roof_L2', 'roof_L1')
    color_map = {
        'MEM':  '#1f77b4',  # blue
        'L3':   '#ff7f0e',  # orange
        'L2':   '#2ca02c',  # green
        'L1':   '#d62728',  # red
    }
    roofs = []
    for name in order:
        v = d.get(name)
        if v is not None and v > 0:
            lvl = name.split('_',1)[1]
            roofs.append((lvl, to_bytes_per_sec(v), color_map.get(lvl, None)))

    if not roofs:
        raise RuntimeError("No roofs in CSV (roof_L1/roof_L2/roof_L3/roof_MEM)")

    # Compute ceiling (instr/s)
    compute = d.get('roof_compute_instr_per_sec_est')

    # Knees (OI where each bandwidth line hits compute ceiling)
    knees = []
    if compute and compute > 0:
        for _, B, _ in roofs:
            knees.append(compute / B)

    # X-range: cover app point and knees (if any)
    x_candidates = [app_x]
    if knees:
        x_candidates += knees
    x_min = max(1e-3, min(x_candidates) / 10.0)
    x_max = max(app_x * 10.0, (max(knees) * 10.0 if knees else app_x * 10.0))
    xs = logspace(x_min, x_max, n=256)

    # Scale Y to GInstr/s for GFLOPS-like ticks
    SCALE = 1e-9
    def gy(y): return y * SCALE

    fig, ax = plt.subplots(figsize=(8.4, 5.8))

    # Shaded regions and captions (if compute present)
    if compute and compute > 0 and knees:
        knee_left  = min(knees)   # L1 knee (highest BW)
        knee_right = max(knees)   # MEM knee (lowest BW)
        ax.axvspan(x_min, knee_left, facecolor='#d62728', alpha=0.06, lw=0)  # memory-ish
        ax.axvspan(knee_left, knee_right, facecolor='#aaaaaa', alpha=0.06, lw=0)  # mixed
        ax.axvspan(knee_right, x_max, facecolor='#1f77b4', alpha=0.06, lw=0)  # compute-ish

        # Bottom-anchored text labels
        trans = ax.get_xaxis_transform()  # y in axes coords
        ax.text( (x_min*knee_left)**0.5, 0.03, "Memory bound?",
                 transform=trans, ha='center', va='bottom', fontsize=10, color='#8c564b')
        ax.text( (knee_left*knee_right)**0.5, 0.03, "Bound by compute\nand memory roofs?",
                 transform=trans, ha='center', va='bottom', fontsize=10, color='#4d4d4d')
        ax.text( (knee_right*x_max)**0.5, 0.03, "Compute bound?",
                 transform=trans, ha='center', va='bottom', fontsize=10, color='#1f77b4')

    # Draw each roof (clipped at compute)
    for label, B, color in roofs:
        ys = [x * B for x in xs]
        if compute and compute > 0:
            ys = [min(y, compute) for y in ys]
            knee = compute / B
        else:
            knee = None

        ax.loglog(xs, [gy(y) for y in ys],
                  linewidth=2.0, label=f"{label} roof", color=color)

        # inline label on the sloped part
        try:
            x_text = mid_before_knee(xs, knee)
            y_text = gy(min(x_text * B, compute if compute else x_text * B))
            ax.text(x_text, y_text*1.05, f"{label}",
                    fontsize=9, color=color)
        except Exception:
            pass

    # Compute roof line (flat, from first knee)
    if compute and compute > 0 and knees:
        start = min(knees)
        xs2 = [x for x in xs if x >= start]
        if xs2:
            ax.loglog(xs2, [gy(compute)]*len(xs2), linestyle='--', linewidth=2.2,
                      label="Compute roof (instr/s est)", color='#9467bd')

    # App point
    ax.loglog([app_x], [gy(app_y)], marker='o', markersize=8,
              linestyle='None', label="PostgreSQL (tpcc)", color='#6b6b6b')

    # Axes labels & title (GFLOPS-like style)
    ax.set_xlabel("Operational intensity (Instructions / Byte)")
    ax.set_ylabel("Performance (Instructions / second)")  # GFLOPS-like labeling for Instructions
    ax.set_title(title or "Instruction Roofline (PostgreSQL + BenchBase)")

    # Finer grid
    ax.set_axisbelow(True)
    ax.grid(which='major', ls=':', lw=0.8, alpha=0.35)
    ax.grid(which='minor', ls=':', lw=0.5, alpha=0.20)
    ax.minorticks_on()

    # Legend: outside + horizontal
    handles, labels = ax.get_legend_handles_labels()
    ax.legend(handles, labels, loc='lower center',
              bbox_to_anchor=(0.5, 1.02), ncol=3, frameon=False)

    # Layout with room for the legend above
    plt.tight_layout(rect=(0, 0, 1, 0.92))

    if savepath:
        plt.savefig(savepath, bbox_inches='tight', dpi=160)
    else:
        plt.show()

# ---------- CLI ----------
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 plot_roofline_v2.py /path/to/roofline_summary.csv [output.png]")
        sys.exit(1)
    csv_path = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) >= 3 else None
    plot_roofline(str(csv_path), title=None, savepath=str(out) if out else None)
