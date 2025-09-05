#!/usr/bin/env bash
set -Eeuo pipefail
ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
OUT_CSV="${ARTI_ROOT}/memory_classification.csv"
SUT="${SUT:-postgresql}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

classify(){
  local sum_json="$1"
  python3 - "$sum_json" <<'PY'
import sys,json
j=json.load(open(sys.argv[1]))
cm=j.get('cache_misses',0.0)
cr=j.get('cache_references',1.0)
ins=j.get('instructions',1.0)
cy=j.get('cycles',1.0)
mpki=(cm/ins)*1000.0
cpi=(cy/ins)
mr=(cm/cr)
is_mem = (mpki>=10.0 and cpi>=1.0 and mr>=0.25)
print(("memory-bound" if is_mem else "compute-bound"), mpki, cpi, mr)
PY
}

echo "[${TS}] Classifying perf summaries in $LOG_DIR"
touch "$OUT_CSV"
mb=0; total=0
for f in $(ls -1t "$LOG_DIR"/perf_*_summary.json 2>/dev/null || true); do
  sut="$(basename "$f" | cut -d_ -f2)"
  read cls mpki cpi mr < <(classify "$f")
  echo "$TS,$sut,$f,$mpki,$cpi,$mr,$cls" >> "$OUT_CSV"
  total=$((total+1)); [ "$cls" = "memory-bound" ] && mb=$((mb+1))
done

if [ "$total" -gt 0 ] && [ $((mb*100/total)) -ge 60 ]; then
  echo "[${TS}] ✅ Significant memory-boundedness confirmed ($mb/$total)"
  echo "confirmed" > "$ARTI_ROOT/memory_confirmed.flag"
else
  echo "[${TS}] ⚠️  Not consistently memory-bound ($mb/$total)"
  rm -f "$ARTI_ROOT/memory_confirmed.flag" || true
fi

echo "[${TS}] CSV → $OUT_CSV"
