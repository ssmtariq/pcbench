#!/usr/bin/env python3
"""
best_redisconfig_finder.py – choose the best Redis configuration from
TUNA’s tuning results.

This script mirrors the logic of ``best_nginx_config_finder.py``: it
ensures that the TUNA repository is available locally, locates the
``full_seed1.csv`` file in ``src/results_redis`` and selects the
configuration with the highest reported performance.  The CSV file
contains three columns:

  - ``CleanConfig``: a stringified Python dict of Redis settings
  - ``Budget``: numeric value analogous to ``Worker`` (optional filter)
  - ``Reported Value``: measured throughput to maximise

The resulting configuration is written both as pretty‑printed JSON and
as a ``redis.conf``–style file.

Example usage:

  python3 best_redisconfig_finder.py \
      --min-budget 0 \
      --out-json TUNA_best_redis_config.json \
      --out-conf TUNA_best_redis_config.conf

If you do not supply a ``--csv`` path, the script will clone the
``ssmtariq/TUNA`` repository (development branch) into a temporary
directory and read ``src/results_redis/full_seed1.csv`` from that
checkout.  You can override the CSV location with ``--csv``.
"""

import argparse
import ast
import json
import logging
import subprocess
import sys
import tempfile
from pathlib import Path

import pandas as pd

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument(
        "--csv",
        default=None,
        help=(
            "Path to full_seed1.csv; if omitted, the script clones the "
            "TUNA repository and uses src/results_redis/full_seed1.csv from that checkout"
        ),
    )
    p.add_argument(
        "--min-budget",
        type=float,
        default=None,
        help="Optional: keep rows where Budget >= this value",
    )
    p.add_argument(
        "--goal",
        choices=["max", "min"],
        default="max",
        help="Maximize or minimize Reported Value (default: max)",
    )
    p.add_argument(
        "--out-json",
        default="TUNA_best_redis_config.json",
        help="Output file for the JSON config",
    )
    p.add_argument(
        "--out-conf",
        default="TUNA_best_redis_config.conf",
        help="Output file for the redis.conf config",
    )
    return p.parse_args()

# Constants pointing to the TUNA repo and CSV location.  Change these
# if you wish to target a different repository or location.
REPO_URL = "https://github.com/ssmtariq/TUNA"
CSV_REL_PATH = Path("src/results_redis/full_seed1.csv")
# Use a temporary directory under the system temp area for the clone
TMPDIR = Path(tempfile.gettempdir()) / "TUNA_ssmtariq"


def clone_if_needed(url: str, dest: Path) -> Path:
    """Clone the repository at ``url`` into ``dest`` if it doesn't exist."""
    if dest.exists():
        return dest
    logging.info("Cloning %s into %s", url, dest)
    # Clone only the development branch to reduce download size
    subprocess.run(
        ["git", "clone", "--depth", "1", "--branch", "development", url, str(dest)],
        check=True,
    )
    return dest

def load_csv(path: Path) -> pd.DataFrame:
    """Read a CSV and validate required columns."""
    try:
        df = pd.read_csv(path)
    except Exception:
        # fallback to python engine if quoting is funky
        df = pd.read_csv(path, engine="python")
    need = {"CleanConfig", "Budget", "Reported Value"}
    missing = need.difference(df.columns)
    if missing:
        sys.exit(f"✗ Missing columns {missing} in {path}")
    # strip an auto‑generated index column if present
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

def main() -> None:
    args = parse_args()
    # Configure basic logging
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    # Determine the CSV path: if the user supplied --csv and the file exists,
    # use it directly.  Otherwise clone the repo and use the default path.
    if args.csv and Path(args.csv).exists():
        csv_path = Path(args.csv)
    else:
        repo_dir = clone_if_needed(REPO_URL, TMPDIR)
        csv_path = repo_dir / CSV_REL_PATH
        if not csv_path.exists():
            # try to find the CSV somewhere under the repository
            matches = list(repo_dir.rglob("full_seed1.csv"))
            if not matches:
                sys.exit("✗ No full_seed1.csv found in the cloned TUNA repository")
            csv_path = matches[0]

    logging.info("Reading tuning results from %s", csv_path)
    df = load_csv(csv_path)
    best = pick_best(df, args.min_budget, args.goal)
    cfg = sanitize_config_str(best["CleanConfig"])
    write_json(cfg, Path(args.out_json))
    write_redis_conf(cfg, Path(args.out_conf))
    print("---")
    print("Budget        :", best["Budget"])
    print("Reported Value:", best["Reported Value"])
    # Print the source CSV relative to the repo when applicable
    try:
        rel = csv_path.relative_to(repo_dir)  # type: ignore[name-defined]
        print("Source CSV    :", rel)
    except Exception:
        print("Source CSV    :", csv_path)

if __name__ == "__main__":
    main()