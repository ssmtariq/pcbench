#!/usr/bin/env bash
# Pretty memory classifier with explanations + CSV & flag behavior preserved.
set -Eeuo pipefail

ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
OUT_CSV="${OUT_CSV:-$ARTI_ROOT/memory_classification.csv}"
SUT_DEFAULT="${SUT:-postgresql}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

# Thresholds (documented for clarity)
MPKI_TH=10.0        # misses per kilo-instruction
CPI_TH=1.0          # cycles per instruction
MISSRATIO_TH=0.25   # cache_misses / cache_references

explain_one() {
  local f="$1"
  python3 - "$f" "$MPKI_TH" "$CPI_TH" "$MISSRATIO_TH" <<'PY'
import sys, json, math, os
f, MPKI_TH, CPI_TH, MR_TH = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
j = json.load(open(f))
# raw
cy = float(j.get('cycles', 0.0))
ins = float(j.get('instructions', 1.0))
cr = float(j.get('cache_references', 1.0))
cm = float(j.get('cache_misses', 0.0))
br = float(j.get('branches', 0.0))
bm = float(j.get('branch_misses', 0.0))
csw = float(j.get('context_switches', 0.0))
majf = float(j.get('major_faults', 0.0))

# derived
mpki = (cm / ins) * 1000.0
cpi  = (cy / ins)
mr   = (cm / cr)

is_mem = (mpki >= MPKI_TH and cpi >= CPI_TH and mr >= MR_TH)
cls = "memory-bound" if is_mem else "compute-bound"

def fmt(x): 
    return f"{x:.6f}" if x < 1000 else f"{x:.3f}"

# Reasons
reasons = []
def req(ok, name, val, th, sense):
    if ok:
        reasons.append(f"✓ {name} {sense} {th} (observed={fmt(val)})")
    else:
        reasons.append(f"✗ {name} NOT {sense} {th} (observed={fmt(val)})")

req(mpki >= MPKI_TH, "MPKI", mpki, MPKI_TH, "≥")
req(cpi  >= CPI_TH,  "CPI",  cpi,  CPI_TH,  "≥")
req(mr   >= MR_TH,   "Miss Ratio", mr, MR_TH, "≥")

sut = os.path.basename(f).split('_')[1] if '_' in os.path.basename(f) else "unknown"

# Pretty print block
print("")
print("────────────────────────────────────────────────────────")
print(f"SUT: {sut}")
print(f"File: {f}")
print("Raw counters:")
print(f"  instructions         = {fmt(ins)}")
print(f"  cycles               = {fmt(cy)}")
print(f"  cache_references     = {fmt(cr)}")
print(f"  cache_misses         = {fmt(cm)}")
print(f"  branches             = {fmt(br)}")
print(f"  branch_misses        = {fmt(bm)}")
print(f"  context_switches     = {fmt(csw)}")
print(f"  major_faults         = {fmt(majf)}")
print("Derived metrics:")
print(f"  MPKI  = cache_misses / instructions * 1000     = {fmt(mpki)}")
print(f"  CPI   = cycles / instructions                   = {fmt(cpi)}")
print(f"  MissR = cache_misses / cache_references        = {fmt(mr)}")
print("")
print("Decision rule (must meet ALL 3 to be memory-bound):")
print(f"  MPKI ≥ {MPKI_TH}  AND  CPI ≥ {CPI_TH}  AND  MissR ≥ {MR_TH}")
for r in reasons: print("   " + r)
print(f"\nVerdict: {cls}")
print("────────────────────────────────────────────────────────")

# Emit a MACHINE-READABLE line at the end for the caller (CSV writer)
print(f"CSV::{sut}::{f}::{mpki}::{cpi}::{mr}::{cls}")
PY
}

echo "[${TS}] Classifying perf summaries in $LOG_DIR"
touch "$OUT_CSV"

mb=0; total=0
for f in $(ls -1t "$LOG_DIR"/perf_*_summary.json 2>/dev/null || true); do
  block="$(explain_one "$f")"
  echo "$block"
  # Parse the final machine-readable line for CSV:
  last=$(echo "$block" | tail -n 1)
  if [[ "$last" == CSV::* ]]; then
    IFS="::" read -r _ sut path mpki cpi mr cls <<< "$last"
  else
    sut="$SUT_DEFAULT"; mpki=""; cpi=""; mr=""; cls="compute-bound"
  fi
  echo "$TS,$sut,$path,$mpki,$cpi,$mr,$cls" >> "$OUT_CSV"
  total=$((total+1)); [[ "$cls" == "memory-bound" ]] && mb=$((mb+1))
done

if [ "$total" -gt 0 ] && [ $((mb*100/total)) -ge 60 ]; then
  echo "[${TS}] ✅ Significant memory-boundedness confirmed ($mb/$total)"
  echo "confirmed" > "$ARTI_ROOT/memory_confirmed.flag"
else
  echo "[${TS}] ⚠️  Not consistently memory-bound ($mb/$total)"
  rm -f "$ARTI_ROOT/memory_confirmed.flag" || true
fi

echo "[${TS}] CSV → $OUT_CSV"
