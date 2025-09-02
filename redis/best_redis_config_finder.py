#!/usr/bin/env python3
"""
best_redisconfig_finder.py – choose the best Redis configuration from
TUNA’s tuning results.

This script ensures that the TUNA repository is available locally (if needed),
locates the ``full_seed1.csv`` file in ``src/results_redis`` and selects the
configuration evaluated at the **maximum Budget**, then picks the row with the
best (maximum) ``Reported Value``. The resulting configuration is written both
as pretty-printed JSON and as a ``redis.conf``–style file.

Just run:

  python3 best_redisconfig_finder.py
"""

import ast
import json
import logging
import subprocess
import sys
import tempfile
from pathlib import Path

import pandas as pd
import re

# Constants pointing to the TUNA repo and CSV location.
REPO_URL = "https://github.com/ssmtariq/TUNA"
CSV_REL_PATH = Path("src/results_redis/full_seed1.csv")
# Use a temporary directory under the system temp area for the clone
TMPDIR = Path(tempfile.gettempdir()) / "TUNA_ssmtariq"
CSV = None  # Path to full_seed1.csv; if None, clone TUNA and use src/results_redis/full_seed1.csv
MIN_BUDGET = 0  # kept for compatibility (unused by max-budget selection logic)
GOAL = "max"  # maximize or minimize Reported Value (kept for compatibility; we maximize)
OUT_JSON = "TUNA_best_redis_config.json"
OUT_CONF = "TUNA_best_redis_config.conf"


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
    # strip an auto-generated index column if present
    if "Unnamed: 0" in df.columns:
        df = df.drop(columns=["Unnamed: 0"])
    return df


def pick_best(df: pd.DataFrame) -> pd.Series:
    """
    Choose rows evaluated at the **maximum Budget**, then select the one with the
    largest absolute Reported Value. Add tracing to show what's considered and why.
    """
    if df.empty:
        sys.exit("✗ No rows in CSV.")

    # Trace budgets present
    budgets = sorted(pd.unique(df["Budget"]))
    logging.info("Budgets present: %s", budgets)

    max_budget = df["Budget"].max()
    candidates = df[df["Budget"] == max_budget].copy()
    logging.info("Max budget=%s; candidate rows=%d", max_budget, len(candidates))

    if candidates.empty:
        sys.exit("✗ No rows at maximum Budget.")

    # Ensure numeric (just in case CSV has strings)
    candidates["__rv"] = pd.to_numeric(candidates["Reported Value"], errors="coerce")

    # Show a quick snapshot of Reported Values at this budget
    logging.info("Reported Value (first 10, raw) at max budget: %s",
                 candidates["__rv"].head(10).tolist())
    logging.info("Reported Value (first 10, abs) at max budget: %s",
                 candidates["__rv"].abs().head(10).tolist())

    # Order by descending absolute reported value
    order = candidates["__rv"].abs().sort_values(ascending=False).index

    # Walk candidates by |Reported Value| and pick first whose CleanConfig parses
    for rank, idx in enumerate(order, 1):
        rv = candidates.at[idx, "__rv"]
        cfg = candidates.at[idx, "CleanConfig"]
        try:
            # Use the existing sanitizer (handles np.str_(...), int(...), etc.)
            _ = sanitize_config_str(cfg)
            logging.info(
                "Pick rank %d: idx=%s rv=%s abs=%s (parsable=YES)",
                rank, idx, rv, (abs(rv) if pd.notna(rv) else None)
            )
            return candidates.loc[idx]
        except Exception as e:
            logging.info(
                "Skip rank %d: idx=%s rv=%s abs=%s (parsable=NO: %s)",
                rank, idx, rv, (abs(rv) if pd.notna(rv) else None), e
            )
            continue


    # Fallback: if none parse, still return the largest-|rv| row
    idx = candidates["__rv"].abs().idxmax()
    rv = candidates.at[idx, "__rv"]
    logging.info("Fallback pick idx=%s rv=%s abs=%s (no parsable CleanConfig found)",
                 idx, rv, (abs(rv) if pd.notna(rv) else None))
    return candidates.loc[idx]


# Precompile once at module import
_NP_STR_RE = re.compile(r"np\.str_\((['\"])(.*?)\1\)")

def sanitize_config_str(s: str) -> dict:
    # 1) Normalize: convert np.str_('foo') → 'foo'
    s_norm = _NP_STR_RE.sub(r"'\2'", s)

    # 2) Try strict safe parsing first
    try:
        d = ast.literal_eval(s_norm)
        return {str(k).strip(): v for k, v in d.items()}
    except Exception:
        # 3) Very restricted fallback (only simple constructors)
        safe_funcs = {"int": int, "float": float, "str": str, "bool": bool}
        d = eval(s_norm, {"__builtins__": {}}, safe_funcs)
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
    # Configure basic logging
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    # Determine the CSV path: if CSV is set and exists, use it directly.
    # Otherwise clone the repo and use the default path.
    if CSV and Path(CSV).exists():
        csv_path = Path(CSV)
        repo_dir = None
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
    best = pick_best(df)
    cfg = sanitize_config_str(best["CleanConfig"])
    write_json(cfg, Path(OUT_JSON))
    write_redis_conf(cfg, Path(OUT_CONF))
    print("---")
    print("Budget        :", best["Budget"])
    print("Reported Value:", best["Reported Value"])
    # Print the source CSV relative to the repo when applicable
    try:
        if repo_dir is not None:
            rel = csv_path.relative_to(repo_dir)
            print("Source CSV    :", rel)
        else:
            print("Source CSV    :", csv_path)
    except Exception:
        print("Source CSV    :", csv_path)


if __name__ == "__main__":
    main()
