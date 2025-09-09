#!/usr/bin/env bash
# 4_classify_memory.sh — confidence-based memory sensitivity classifier (LLC/TLB/Topdown aware)
set -Eeuo pipefail

ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
OUT_CSV="${OUT_CSV:-$ARTI_ROOT/memory_classification.csv}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

# Heuristics (tuned for OLTP-like workloads)
CPI_TH=0.80
LLC_MPKI_TH=3.0
MISSR_TH=0.10
BEBOUND_TH=0.30

explain_one() {
  local f="$1"
  python3 - "$f" "$CPI_TH" "$LLC_MPKI_TH" "$MISSR_TH" "$BEBOUND_TH" <<'PY'
import sys, json, os
f, CPI_TH, LLC_MPKI_TH, MISSR_TH, BEBOUND_TH = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
J = json.load(open(f))

# raw counters (default 0 if absent)
def g(k, d=0.0): return float(J.get(k, d))
ins  = g('instructions')
cy   = g('cycles')
cr   = g('cache_references')
cm   = g('cache_misses')
llcL = g('llc_loads')
llcM = g('llc_load_misses')
dtlbM= g('dtlb_load_misses')
be   = g('topdown_be_bound')

# derived (guard against /0)
def z(x): return x if x>0 else 1.0
mpki_legacy = (cm / z(ins)) * 1000.0
llc_mpki    = (llcM / z(ins)) * 1000.0
cpi         = (cy / z(ins))
missr       = (cm / z(cr))

# evidence votes
votes = []
if cpi >= CPI_TH:                  votes.append(("CPI", cpi, CPI_TH))
if llc_mpki >= LLC_MPKI_TH:        votes.append(("LLC_MPKI", llc_mpki, LLC_MPKI_TH))
if missr >= MISSR_TH:              votes.append(("MissR", missr, MISSR_TH))
if be >= BEBOUND_TH:               votes.append(("BE_bound", be, BEBOUND_TH))

conf = len(votes) / 4.0  # 0..1
cls  = "memory-sensitive" if conf >= 0.5 else "inconclusive/lean-compute"

def fmt(x): 
  return f"{x:.6f}" if x < 1000 else f"{x:.3f}"

sut = os.path.basename(f).split('_')[1] if '_' in os.path.basename(f) else "unknown"

print("\n────────────────────────────────────────────────────────")
print(f"SUT: {sut}")
print(f"File: {f}")
print("Raw counters (subset):")
print(f"  instructions = {fmt(ins)}")
print(f"  cycles       = {fmt(cy)}")
print(f"  cache_refs   = {fmt(cr)}")
print(f"  cache_miss   = {fmt(cm)}")
print(f"  LLC_loads    = {fmt(llcL)}")
print(f"  LLC_misses   = {fmt(llcM)}")
print(f"  dTLB_misses  = {fmt(dtlbM)}")
print(f"  topdown_be   = {fmt(be)}")
print("Derived:")
print(f"  CPI          = {fmt(cpi)}")
print(f"  MPKI (legacy)= {fmt(mpki_legacy)}")
print(f"  LLC-MPKI     = {fmt(llc_mpki)}")
print(f"  Miss Ratio   = {fmt(missr)}")
print("\nDecision (evidence-based):")
print(f"  Need ≥2/4 signals: CPI≥{CPI_TH}, LLC-MPKI≥{LLC_MPKI_TH}, MissR≥{MISSR_TH}, BE_bound≥{BEBOUND_TH}")
for n,v,t in votes: print(f"   ✓ {n} passed (obs={fmt(v)} ≥ {t})")
if len(votes)<2: print(f"   ✗ only {len(votes)}/4 signals")

print(f"\nVerdict: {cls}   Confidence: {conf:.2f}")
print("────────────────────────────────────────────────────────")
print(f"CSV::{sut}::{f}::{fmt(mpki_legacy)}::{fmt(llc_mpki)}::{fmt(cpi)}::{fmt(missr)}::{fmt(be)}::{cls}::{conf:.3f}")
PY
}

echo "[${TS}] Classifying perf summaries in $LOG_DIR"
touch "$OUT_CSV"

for f in $(ls -1t "$LOG_DIR"/perf_*_summary.json 2>/dev/null || true); do
  block="$(explain_one "$f")"
  echo "$block"
  last=$(echo "$block" | tail -n 1)
  if [[ "$last" == CSV::* ]]; then
    IFS="::" read -r _ sut path mpki llc_mpki cpi missr be cls conf <<< "$last"
    echo "$TS,$sut,$path,$mpki,$llc_mpki,$cpi,$missr,$be,$cls,$conf" >> "$OUT_CSV"
  fi
done

echo "[${TS}] CSV → $OUT_CSV"
