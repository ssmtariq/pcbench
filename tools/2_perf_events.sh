#!/usr/bin/env bash
set -Eeuo pipefail
ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"
OUT="$ARTI_ROOT/perf_events.txt"

echo "[$(date +%T)] Capturing 'perf list' → $OUT"
if [ -s "$OUT" ]; then
  echo "[$(date +%T)] Already exists; skipping."
else
  perf list > "$OUT" 2>&1 || echo "[!] perf list failed — check perf permissions" >&2
fi
echo "[$(date +%T)] Done."
