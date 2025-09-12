#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import csv, math, sys
from pathlib import Path
import numpy as np
import matplotlib as mpl
import matplotlib.pyplot as plt

# All text in Times New Roman
mpl.rcParams['font.family'] = 'Times New Roman'

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
    return [10.0 ** (math.log10(x0) + i*(math.log10(x1/x0)/(n-1))) for i in range(n)]

def line_angle_deg(ax, x0, y0, x1, y1):
    """Angle of the segment (x0,y0)->(x1,y1) in display coords, for text rotation."""
    (X0, Y0) = ax.transData.transform((x0, y0))
    (X1, Y1) = ax.transData.transform((x1, y1))
    return np.degrees(np.arctan2(Y1 - Y0, X1 - X0))

def annotate_app_point(ax, app_x, app_y, gy_func):
    """
    Plot the application point (PostgreSQL tpcc) and annotate with (x,y) values.
    If the point is very close to the x-axis, put label above; otherwise below.
    """
    x_val = app_x
    y_val = gy_func(app_y)
    # plot the grey dot
    ax.loglog([x_val], [y_val],
              marker='o', markersize=8, linestyle='None',
              label="PostgreSQL (tpcc)", color='#6b6b6b')

    # decide label placement relative to x-axis
    ymin, ymax = ax.get_ylim()
    decades_above = math.log10(max(y_val, ymin*1.0000001) / ymin)

    THRESH = 0.6  # ~0.6 decade (~4x above ymin)
    if decades_above < THRESH:
        offset = (0, 10)   # above
        va = 'bottom'
    else:
        offset = (0, -12)  # below
        va = 'top'

    # value pair label
    label_txt = f"({x_val:.3g} Instr/Byte, {y_val:.3g} GInstr/s)"
    ax.annotate(
        label_txt,
        xy=(x_val, y_val),
        xycoords='data',
        textcoords='offset points',
        xytext=offset,
        ha='center', va=va,
        fontsize=9, color='#4d4d4d',
        bbox=dict(facecolor='white', alpha=0.5, edgecolor='none', pad=2.5),
    )

# ---------- main plot ----------
def plot_roofline(csv_path, title=None, savepath=None):
    d = read_summary(csv_path)

    # App point
    app_x = d.get('app_instr_per_byte')
    app_y = d.get('app_instr_per_sec')
    if app_x is None or app_y is None:
        raise RuntimeError("Missing app point (app_instr_per_byte or app_instr_per_sec) in CSV")

    # Bandwidth roofs (Bytes/s)
    order = ('roof_MEM', 'roof_L3', 'roof_L2', 'roof_L1')  # low->high BW
    color_map = {'MEM':'#1f77b4','L3':'#ff7f0e','L2':'#2ca02c','L1':'#d62728'}
    roofs = []
    for name in order:
        mbs = d.get(name)  # MiB/s
        if mbs and mbs > 0:
            lvl = name.split('_',1)[1]
            roofs.append((lvl, to_bytes_per_sec(mbs), mbs, color_map.get(lvl)))

    if not roofs:
        raise RuntimeError("No roofs (roof_L1/roof_L2/roof_L3/roof_MEM) in CSV")

    # Compute ceilings
    compute_instr = d.get('roof_compute_instr_per_sec_est')  # instr/s (from IPC*freq*cores)
    # Optional FLOP ceilings (GFLOPS) – if you add these to CSV the label will switch automatically
    sp_fma_gflops = d.get('roof_compute_sp_fma_gflops')
    dp_fma_gflops = d.get('roof_compute_dp_fma_gflops')
    scalar_add_gflops = d.get('roof_compute_scalar_add_gflops')

    # Knees (where each BW roof hits the compute ceiling)
    knees = []
    if compute_instr and compute_instr > 0:
        for _, B, _, _ in roofs:
            knees.append(compute_instr / B)

    # X range
    x_candidates = [app_x] + (knees if knees else [])
    x_min = max(1e-3, min(x_candidates) / 10.0)
    x_max = max(app_x * 10.0, (max(knees) * 10.0 if knees else app_x * 10.0))
    xs = logspace(x_min, x_max, n=256)

    # Scale Y to GInstr/s (GFLOPS-like display for instruction roofline)
    SCALE = 1e-9
    def gy(y): return y * SCALE

    fig, ax = plt.subplots(figsize=(8.8, 6.0))

    # Shaded regions
    if compute_instr and compute_instr > 0 and knees:
        knee_left  = min(knees)   # highest BW knee
        knee_right = max(knees)   # lowest BW knee
        ax.axvspan(x_min, knee_left,  facecolor='#d62728', alpha=0.06, lw=0)
        ax.axvspan(knee_left, knee_right, facecolor='#aaaaaa', alpha=0.06, lw=0)
        ax.axvspan(knee_right, x_max,  facecolor='#1f77b4', alpha=0.06, lw=0)
        trans = ax.get_xaxis_transform()
        ax.text((x_min*knee_left)**0.5,   0.03, "Memory bound", transform=trans,
                ha='center', va='bottom', fontsize=10, color='#8c564b')
        ax.text((knee_left*knee_right)**0.5, 0.03, "Bound by compute\nand memory roofs",
                transform=trans, ha='center', va='bottom', fontsize=10, color='#4d4d4d')
        ax.text((knee_right*x_max)**0.5,  0.03, "Compute bound", transform=trans,
                ha='center', va='bottom', fontsize=10, color='#1f77b4')

    # ---- stable rotation for memory labels (slope 1 on log-log axes) ----
    def slope1_angle_deg(ax_):
        (X0, Y0) = ax_.transData.transform((1.0, 1.0))
        (X1, Y1) = ax_.transData.transform((10.0, 10.0))
        return np.degrees(np.arctan2(Y1 - Y0, X1 - X0))
    angle_slope1 = slope1_angle_deg(ax)

    # Draw roofs + place labels at the beginning of each sloped segment
    for label, B, mbs, color in roofs:
        ys = [x * B for x in xs]
        knee = None
        if compute_instr and compute_instr > 0:
            ys   = [min(y, compute_instr) for y in ys]
            knee = compute_instr / B

        ax.loglog(xs, [gy(y) for y in ys], linewidth=2.0, label=f"{label} roof", color=color)

        # --- Memory roofline label: start near left and align with slope-1 precisely ---
        try:
            base = x_min * 1.20
            if knee:
                x_start = min(base, knee * 0.55)
                if x_start >= knee:
                    x_start = knee * 0.5
            else:
                x_start = base

            y_start = x_start * B
            if compute_instr and compute_instr > 0:
                y_start = min(y_start, compute_instr)

            gbps = (mbs / 1000.0)   # LIKWID MBytes/s → GB/s
            txt  = f"{label} Bandwidth: {gbps:.2f} GB/s"

            # Offset: put L3 label *below* the line, others above
            if label == "L3":
                offset = (2, -4)   # below line
                va = 'top'
            else:
                offset = (2, 10)    # above line
                va = 'center'

            ax.annotate(
                txt,
                xy=(x_start, gy(y_start)),
                xycoords='data',
                textcoords='offset points',
                xytext=offset,
                rotation=angle_slope1-3,
                rotation_mode='anchor',
                ha='left', va=va,
                color=color, fontsize=9,
                bbox=dict(facecolor='white', alpha=0.35, edgecolor='none', pad=0.8),
                clip_on=True
            )
        except Exception:
            pass


    # Compute roof (flat + label)
    if compute_instr and compute_instr > 0 and knees:
        start = min(knees)
        xs2 = [x for x in xs if x >= start]
        if xs2:
            ax.loglog(xs2, [gy(compute_instr)]*len(xs2),
                      linestyle='--', linewidth=2.2,
                      label="Compute roof (instr/s est)", color='#9467bd')

            # --- Label for compute roof using available data ---
            if sp_fma_gflops:
                comp_label = f"SP Vector FMA Peak: {sp_fma_gflops:.2f} GFLOPS"
            elif dp_fma_gflops:
                comp_label = f"DP Vector FMA Peak: {dp_fma_gflops:.2f} GFLOPS"
            elif scalar_add_gflops:
                comp_label = f"Scalar Add Peak: {scalar_add_gflops:.2f} GFLOPS"
            else:
                comp_label = f"Instruction Peak (est.): {compute_instr*SCALE:.2f} GInstr/s"

            xcl = start * 1.02
            ax.text(xcl, gy(compute_instr)*1.02, comp_label,
                    fontsize=10, color='#9467bd', ha='left', va='bottom',
                    bbox=dict(facecolor='white', alpha=0.35, edgecolor='none', pad=1.0))

    # App point with annotation
    annotate_app_point(ax, app_x, app_y, gy)

    # Axes & title
    ax.set_xlabel("Operational intensity (Instr/Byte)")
    ax.set_ylabel("Performance (GInstr/s)")
    ax.set_title(title or "Instruction Roofline (PostgreSQL + BenchBase)", pad=14)

    # Grid
    ax.set_axisbelow(True)
    ax.grid(which='major', ls=':', lw=0.8, alpha=0.35)
    ax.grid(which='minor', ls=':', lw=0.5, alpha=0.20)
    ax.minorticks_on()

    # Legend outside & horizontal
    handles, labels = ax.get_legend_handles_labels()
    ax.legend(handles, labels, loc='lower center',
              bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)

    plt.tight_layout(rect=(0, 0, 1, 0.84))
    if savepath:
        plt.savefig(savepath, bbox_inches='tight', dpi=170)
    else:
        plt.show()

# ---------- CLI ----------
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 plot_roofline_v4.py /path/to/roofline_summary.csv [output.png]")
        sys.exit(1)
    csv_path = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) >= 3 else None
    plot_roofline(str(csv_path), title=None, savepath=str(out) if out else None)
