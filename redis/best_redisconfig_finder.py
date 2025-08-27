#!/usr/bin/env python3
"""
best_redisconfig_finder.py — choose the best Redis config from full_seed1.csv

Input columns (single CSV):
  - CleanConfig      : stringified Python dict of Redis settings
  - Budget           : numeric (analogous to Worker; optional filter)
  - Reported Value   : numeric reward/throughput to maximize

Outputs:
  - TUNA_best_redis_config.json  (machine-readable)
  - TUNA_best_redis_config.conf  (redis.conf-style, ready to run)

Usage:
  python3 best_redisconfig_finder.py \
      --csv src/results_redis/full_seed1.csv \
      --min-budget 0 \
      --out-json TUNA_best_redis_config.json \
      --out-conf TUNA_best_redis_config.conf
"""

import argparse, ast, json, sys
from pathlib import Path
import pandas as pd

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--csv", default="src/results_redis/full_seed1.csv",
                   help="Path to full_seed1.csv")
    p.add_argument("--min-budget", type=float, default=None,
                   help="Optional: keep rows where Budget >= this value")
    p.add_argument("--goal", choices=["max", "min"], default="max",
                   help="Maximize or minimize Reported Value (default: max)")
    p.add_argument("--out-json", default="TUNA_best_redis_config.json")
    p.add_argument("--out-conf", default="TUNA_best_redis_config.conf")
    return p.parse_args()

def load_csv(path: Path) -> pd.DataFrame:
    try:
        df = pd.read_csv(path)
    except Exception:
        # fallback to python engine if quoting is funky
        df = pd.read_csv(path, engine="python")
    need = {"CleanConfig", "Budget", "Reported Value"}
    missing = need.difference(df.columns)
    if missing:
        sys.exit(f"✗ Missing columns {missing} in {path}")
    # strip obvious unnamed index col if present
    if "Unnamed: 0" in df.columns:
        df = df.drop(columns=["Unnamed: 0"])
    return df

def pick_best(df: pd.DataFrame, min_budget, goal) -> pd.Series:
    if min_budget is not None:
        df = df[df["Budget"] >= min_budget]
        if df.empty:
            sys.exit("✗ No candidates pass the Budget filter.")
    metric = "Reported Value"
    if goal == "max":
        idx = df[metric].idxmax()
    else:
        idx = df[metric].idxmin()
    return df.loc[idx]

def sanitize_config_str(s: str) -> dict:
    # CleanConfig strings are Python dict literals with single-quotes;
    # ast.literal_eval handles this safely.
    d = ast.literal_eval(s)
    # normalize keys: trim whitespace
    return {str(k).strip(): v for k, v in d.items()}

def write_json(d: dict, out_json: Path):
    with open(out_json, "w") as fh:
        json.dump(d, fh, indent=2, sort_keys=True)
    print("✓ wrote", out_json)

def write_redis_conf(d: dict, out_conf: Path):
    lines = []
    for k, v in d.items():
        # Booleans in redis.conf are yes/no; but in our CSV they’re often already "yes"/"no"
        if isinstance(v, bool):
            val = "yes" if v else "no"
        else:
            val = str(v)
        lines.append(f"{k} {val}")
    out_conf.write_text("\n".join(lines) + "\n")
    print("✓ wrote", out_conf)

def main():
    args = parse_args()
    csv_path = Path(args.csv)
    df = load_csv(csv_path)
    best = pick_best(df, args.min_budget, args.goal)
    cfg = sanitize_config_str(best["CleanConfig"])
    write_json(cfg, Path(args.out_json))
    write_redis_conf(cfg, Path(args.out_conf))
    print("---")
    print("Budget        :", best["Budget"])
    print("Reported Value:", best["Reported Value"])
    print("Source CSV    :", csv_path)

if __name__ == "__main__":
    main()