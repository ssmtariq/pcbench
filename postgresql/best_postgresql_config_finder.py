#!/usr/bin/env python3
"""
best_pg_cfg.py        –  find the best Postgres configuration across TUNA_run*.csv

Logic
1.  clone (or reuse) the TUNA repo
2.  for every TUNA_run*.csv in sample_configs/cloudlab/postgres/tpcc/
      • skip the first 10 rows
      • keep rows where Worker >= 9          (max-fidelity subset)
3.  concatenate all qualifying rows
4.  pick the row with the highest Performance
5.  save its Config as TUNA_best_pgsql_config.json
"""

import json, pathlib, subprocess, sys, tempfile
import pandas as pd

REPO_URL  = "https://github.com/uw-mad-dash/TUNA"
CSV_GLOB  = "sample_configs/cloudlab/postgres/tpcc/TUNA_run*.csv"
OUT_FILE  = "TUNA_best_pgsql_config.json"
TMPDIR    = pathlib.Path(tempfile.gettempdir()) / "TUNA"

# --------------------------------------------------------------------------- #
def clone_if_needed(url: str, dest: pathlib.Path) -> pathlib.Path:
    if dest.exists():
        return dest
    subprocess.run(["git", "clone", "--depth=1", url, str(dest)], check=True)
    return dest

def load_candidates(csv_path: pathlib.Path) -> pd.DataFrame:
    """Return rows with Worker >= 9 after skipping first 10 lines, else empty df."""
    try:
        df = pd.read_csv(csv_path, skiprows=range(1, 11))    # ➊ skip first 10
    except Exception as e:
        print(f"[WARN] cannot read {csv_path}: {e}", file=sys.stderr)
        return pd.DataFrame()

    if "Worker" not in df.columns or "Performance" not in df.columns:
        print(f"[WARN] missing Worker/Performance in {csv_path}; skipped.", file=sys.stderr)
        return pd.DataFrame()

    return df[df["Worker"] >= 9].assign(__source=str(csv_path))

# --------------------------------------------------------------------------- #
def main() -> None:
    repo_dir   = clone_if_needed(REPO_URL, TMPDIR)
    csv_files  = sorted(repo_dir.glob(CSV_GLOB))
    if not csv_files:
        sys.exit("✗ No TUNA_run*.csv files found!")

    # gather all high-fidelity rows across every file
    all_rows = pd.concat([load_candidates(f) for f in csv_files], ignore_index=True)
    if all_rows.empty:
        sys.exit("✗ No configs were tested with Worker ≥ 9 in any CSV.")

    # choose the global best by Performance
    best_row = all_rows.loc[all_rows["Performance"].idxmax()]

    # Config column is a stringified dict using single quotes
    cfg_dict = json.loads(best_row["Config"].replace("'", '"'))

    with open(OUT_FILE, "w") as fh:
        json.dump(cfg_dict, fh, indent=2, sort_keys=True)

    print("🏆 Best configuration written to", OUT_FILE)
    print("   Worker        :", best_row["Worker"])
    print("   Performance   :", best_row["Performance"])
    print("   Source CSV    :", pathlib.Path(best_row["__source"]).relative_to(repo_dir))

# --------------------------------------------------------------------------- #
if __name__ == "__main__":
    main()
