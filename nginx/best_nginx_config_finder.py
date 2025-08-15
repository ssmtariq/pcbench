#!/usr/bin/env python3
"""
best_ng_cfg.py – find the best Nginx configuration across TUNA_run*.csv

Logic
1.  clone (or reuse) the TUNA repo
2.  for every TUNA_run*.csv in sample_configs/azure/nginx/wikipedia/
      • skip the first 10 rows
      • keep rows where Worker ≥ 9          (high-fidelity subset)
3.  concatenate all qualifying rows
4.  pick the row with the highest Performance
5.  save its Config as TUNA_best_nginx_config.json
"""

import json
import pathlib
import subprocess
import sys
import tempfile
from typing import Iterable
import logging

import pandas as pd

# You can change these constants if you wish to target a different
# repository or workload.  The default values correspond to the Azure
# wikipedia nginx workload from TUNA.
REPO_URL = "https://github.com/uw-mad-dash/TUNA"
CSV_GLOB = "sample_configs/azure/nginx/wikipedia/TUNA_run*.csv"
OUT_FILE = "TUNA_best_nginx_config.json"
TMPDIR = pathlib.Path(tempfile.gettempdir()) / "TUNA"

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s: %(message)s"
)


def clone_if_needed(url: str, dest: pathlib.Path) -> pathlib.Path:
    """Clone the repository at ``url`` into ``dest`` if it doesn't exist."""
    if dest.exists():
        return dest
    subprocess.run(["git", "clone", "--depth=1", url, str(dest)], check=True)
    return dest


def load_candidates(csv_path: pathlib.Path) -> pd.DataFrame:
    """Load a CSV file and return only high-fidelity rows.

    We skip the first 10 header rows (matching TUNA's convention) and
    then keep only those rows whose ``Worker`` field equals the
    maximum ``Worker`` value observed in the file.  These rows
    represent the highest fidelity tuning runs for that CSV.
    """
    logging.info("Reading %s", csv_path)
    try:
        df = pd.read_csv(csv_path, skiprows=range(1, 11))
    except Exception as exc:
        print(f"[WARN] cannot read {csv_path}: {exc}", file=sys.stderr)
        return pd.DataFrame()

    if "Worker" not in df.columns or "Performance" not in df.columns:
        print(f"[WARN] missing Worker/Performance columns in {csv_path}; skipped.", file=sys.stderr)
        return pd.DataFrame()

    # Determine the maximum Worker value in this run and filter down to rows
    # with that Worker count.  This mirrors the idea of using the most
    # complete fidelity from the tuning process.
    max_worker = df["Worker"].max()
    high_fidelity = df[df["Worker"] >= 9].copy()
    high_fidelity["__source"] = str(csv_path)

    # Per-file best performance logging
    if not high_fidelity.empty:
        best_perf = high_fidelity["Performance"].max()
        logging.info("Best Performance in %s: %s (rows considered: %d)", csv_path.name, best_perf, len(high_fidelity))
    else:
        logging.info("No high-fidelity rows (Worker ≥ 9) in %s", csv_path.name)

    return high_fidelity


def gather_all_rows(csv_files: Iterable[pathlib.Path]) -> pd.DataFrame:
    """Concatenate candidate rows from multiple CSV files."""
    dfs = [load_candidates(f) for f in csv_files]
    if not dfs:
        return pd.DataFrame()
    return pd.concat(dfs, ignore_index=True)


def main() -> None:
    repo_dir = clone_if_needed(REPO_URL, TMPDIR)
    csv_files = sorted(repo_dir.glob(CSV_GLOB))
    if not csv_files:
        sys.exit("✗ No TUNA_run*.csv files found under the expected path!")

    all_rows = gather_all_rows(csv_files)
    if all_rows.empty:
        sys.exit("✗ No high-fidelity rows found in any CSV file.")

    # Choose the row with the maximum Performance value across all
    # high-fidelity rows.
    best_row = all_rows.loc[all_rows["Performance"].idxmax()]

    # Parse the Config column (stringified dict using single quotes) into a
    # Python dict.  The Config column often contains single quotes so we
    # replace them with double quotes before calling json.loads.
    try:
        cfg_dict = json.loads(best_row["Config"].replace("'", '"'))
    except json.JSONDecodeError:
        print("[ERROR] Failed to parse the Config field; dumping raw string instead.", file=sys.stderr)
        cfg_dict = {"raw_config": best_row["Config"]}

    # Write the best configuration to disk as pretty-printed JSON.
    with open(OUT_FILE, "w") as fh:
        json.dump(cfg_dict, fh, indent=2, sort_keys=True)

    # Report summary to the console.
    print("🏆 Best nginx configuration written to", OUT_FILE)
    print("   Worker      :", best_row["Worker"])
    print("   Performance :", best_row["Performance"])
    # Show the file name relative to the repo for context.
    try:
        rel = pathlib.Path(best_row["__source"]).relative_to(repo_dir)
        print("   Source CSV  :", rel)
    except Exception:
        print("   Source CSV  :", best_row["__source"])


if __name__ == "__main__":
    main()
