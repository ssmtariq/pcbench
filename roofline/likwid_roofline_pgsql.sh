#!/usr/bin/env bash
# LIKWID Roofline for PostgreSQL + BenchBase (xl170/Ubuntu 22.04)
# - Uses your existing pgsql_bench.sh to drive TPCC
# - Measures L1/L2/L3/memory bandwidth roofs (likwid-bench)
# - Attaches to a running Postgres backend PID (application_name='tpcc') to get app point
# - Computes Instruction/Byte intensity from LIKWID CPI + MEM groups

set -Eeuo pipefail
shopt -s inherit_errexit

# -------------------------- logging and guards ---------------------------------
log()   { printf '\n[%s] %s\n'  "$(date '+%F %T')" "$*"; }
warn()  { printf '\n⚠️  %s\n'  "$*" >&2; }
fatal() { printf '\n❌ %s\n'   "$*" >&2; exit 1; }
trap 'fatal "Command \"${BASH_COMMAND}\" failed (line ${LINENO})"' ERR

need()  { command -v "$1" >/dev/null 2>&1 || fatal "Missing dependency: $1"; }

# -------------------------- inputs / defaults ----------------------------------
# Passed through to your BenchBase runner (pgsql_bench.sh)
WARMUP="${WARMUP:-1}"           # 0|1  (default warmup enabled)
WORKLOAD="${WORKLOAD:-small}"   # small|large|xl  (your script supports these)
ITERATIONS="${ITERATIONS:-1}"   # keep 1 for a single measured run

# LIKWID measurement knobs
APP_MEASURE_S="${APP_MEASURE_S:-45}"  # seconds per LIKWID group on the app
THREADS="${THREADS:-$(nproc)}"        # for likwid-bench roofs
CORES="${CORES:-}"                    # e.g., "2-3" to pin the measured backend
RESULT_ROOT="${RESULT_ROOT:-$HOME/likwid_roofline}"
BENCH_SCRIPT="${BENCH_SCRIPT:-$HOME/pcbench/postgresql/pgsql_bench.sh}"

# -------------------------- sanity checks --------------------------------------
need likwid-perfctr
need likwid-bench
need psql
[ -x "$BENCH_SCRIPT" ] || fatal "Bench script not found or not executable: $BENCH_SCRIPT"

# Best-effort counters/MSR setup (no hard fail if blocked)
sudo modprobe msr 2>/dev/null || true
if [ -w /proc/sys/kernel/perf_event_paranoid ]; then
  echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null 2>&1 || true
fi

# Use distro perfgroups by default unless caller overrides
export LIKWID_PERF_GROUPS="${LIKWID_PERF_GROUPS:-/usr/share/likwid/perfgroups}"

# Lower perf restrictions if possible
if [ -w /proc/sys/kernel/perf_event_paranoid ]; then
  echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null || true
fi

# -------------------------- result workspace -----------------------------------
TS="$(date '+%Y%m%d-%H%M%S')"
OUT="$RESULT_ROOT/$TS"
mkdir -p "$OUT"/{roofs,app,logs}
log "Results directory: $OUT"

# -------------------------- helper: parse LIKWID output ------------------------
# Sum a metric row across columns (or use the single value) from the Metrics table
get_metric_sum() {
  local name="$1" file="$2"
  # Match the metric name between pipes regardless of spacing
  awk -v n="$name" -F '|' '
    BEGIN{sum=0}
    $0 ~ "\\|" && $0 ~ n {
      # last column is usually the single HWThread value; if SUM column exists, prefer it
      # strip non-numeric
      for (i=1;i<=NF;i++) {
        col=$i; gsub(/^[ \t]+|[ \t]+$/,"",col)
        if (col=="SUM") { v=$(i+1); gsub(/[^0-9.\-]/,"",v); if (v!="") {sum=v; found=1; break} }
      }
      if (!found) { v=$NF; gsub(/[^0-9.\-]/,"",v); if (v!="") sum+=v }
      print sum; exit
    }
  ' "$file" 2>/dev/null
}

get_mem_bw_sum() { get_metric_sum "Memory bandwidth \\[MBytes/s\\]" "$1"; }

get_instructions_sum() {
  # Sum INSTR_RETIRED_ANY across HWThread columns in the Events table
  awk -F '|' '/INSTR_RETIRED_ANY/ {
      v=$NF; gsub(/[^0-9.]/,"",v); if (v!="") sum+=v
    } END { if (sum>0) printf "%.0f\n", sum }' "$1" 2>/dev/null
}

get_runtime_s() {
  # Extract measured Runtime (RDTSC) [s]
  awk '/Runtime \(RDTSC\) \[s\]/ {print $NF; exit}' "$1" 2>/dev/null || true
}

# -------------------------- step A: roofs (L1/L2/L3/MEM) -----------------------
log "Step A: Measuring roof bandwidths with likwid-bench (THREADS=$THREADS)"
# We use load/copy kernels with working-set sizes targeted to the hierarchy.
# (These are portable approximations; exact sizes vary by CPU.)
declare -A SZS=( ["L1"]="32kB" ["L2"]="256kB" ["L3"]="2MB" ["MEM"]="2GB" )
for LVL in L1 L2 L3 MEM; do
  OUTF="$OUT/roofs/${LVL}.out"
  case "$LVL" in
    L1|L2|L3)  log "  Roof $LVL: likwid-bench -t load_avx -W N:${SZS[$LVL]}:${THREADS}" ;;
    MEM)       log "  Roof MEM: likwid-bench -t copy_avx -W N:${SZS[$LVL]}:${THREADS}" ;;
  esac
  if [ "$LVL" = "MEM" ]; then
    likwid-bench -t copy_avx -W N:${SZS[$LVL]}:${THREADS} | tee "$OUTF" >/dev/null
  else
    likwid-bench -t load_avx -W N:${SZS[$LVL]}:${THREADS} | tee "$OUTF" >/dev/null
  fi
done
log "  Roof measurements saved to $OUT/roofs/ (inspect to choose peak MBytes/s per level)"

# -------------------------- step B: start BenchBase run -------------------------
log "Step B: Launching your BenchBase run via $BENCH_SCRIPT (WORKLOAD=$WORKLOAD, WARMUP=$WARMUP, ITERATIONS=$ITERATIONS)"
# Your script ensures DB exists, copies configs, loads schema, restarts PG, runs measured execute,
# and prints TPS stats at the end. :contentReference[oaicite:9]{index=9} :contentReference[oaicite:10]{index=10} :contentReference[oaicite:11]{index=11}
LOG_BENCH="$OUT/logs/bench_run.log"
( WARMUP="$WARMUP" WORKLOAD="$WORKLOAD" ITERATIONS="$ITERATIONS" bash "$BENCH_SCRIPT" ) |& tee "$LOG_BENCH" &
BENCH_PID=$!
log "BenchBase runner PID: $BENCH_PID"

# -------------------------- step C: find a tpcc backend PID --------------------
log "Step C: Waiting for a PostgreSQL backend with application_name='tpcc' ..."
PID=""
for _ in $(seq 1 120); do
  PID="$(psql -tAc "SELECT pid FROM pg_stat_activity WHERE application_name='tpcc' AND state <> 'idle' ORDER BY backend_start DESC LIMIT 1;" 2>/dev/null | tr -d ' ')"
  [ -n "$PID" ] && break
  sleep 1
done
[ -z "$PID" ] && fatal "Could not find a Postgres backend for application_name='tpcc'. Is BenchBase running?"

log "Found backend PID: $PID"

# -------------------------- step D: pin the backend (optional) -----------------
if [ -n "${CORES}" ]; then
  log "Pinning backend $PID to cores: $CORES"
  sudo taskset -pc "$CORES" "$PID" >/dev/null || warn "taskset pin failed; continuing"
else
  # If not specified, use the CPU currently running the thread as the core mask
  CURR_CORE="$(ps -o psr= -p "$PID" | awk '{print $1}')"
  CORES="$CURR_CORE"
  log "No CORES provided; measuring on current core: $CORES"
fi

# -------------------------- step E: detect LIKWID groups -----------------------
# Trim leading spaces from `likwid-perfctr -a` output
GROUPS_LIST="$(likwid-perfctr -a 2>/dev/null | sed 's/^[[:space:]]*//')"

pick_group() { grep -q "^$1[[:space:]]" <<<"$GROUPS_LIST" && echo "$1" || true; }

# L1/L2/L3 (prefer simple names, fall back to *CACHE variants)
G_L1="$(pick_group L1D)"; [ -z "$G_L1" ] && G_L1="$(pick_group L1CACHE)"
G_L2="$(pick_group L2)";  [ -z "$G_L2" ]  && G_L2="$(pick_group L2CACHE)"
G_L3="$(pick_group L3)";  [ -z "$G_L3" ]  && G_L3="$(pick_group L3CACHE)"
G_MEM="MEM"

# CPI-capable group: prefer CPI; else TMA; else CACHES (all expose a CPI metric)
pick_cpi_group() {
  if grep -q "^CPI[[:space:]]"    <<<"$GROUPS_LIST"; then echo "CPI";    return; fi
  if grep -q "^TMA[[:space:]]"    <<<"$GROUPS_LIST"; then echo "TMA";    return; fi
  if grep -q "^CACHES[[:space:]]" <<<"$GROUPS_LIST"; then echo "CACHES"; return; fi
  echo ""
}
G_CPI="$(pick_cpi_group)"

log "Detected groups -> L1=${G_L1:-N/A}, L2=${G_L2:-N/A}, L3=${G_L3:-N/A}, MEM=$G_MEM, CPI=${G_CPI:-N/A}"

# -------------------------- step F: measure the app point ----------------------
export LIKWID_PERF_PID="$PID"

measure_group() {
  local G="$1"; local PF="$OUT/app/${G}.out"
  [ -z "$G" ] && return 0
  log "Measuring group $G for ${APP_MEASURE_S}s on cores $CORES (attached to PID $PID)"
  if [ "$(id -u)" -ne 0 ]; then
    sudo -E likwid-perfctr -C "$CORES" -g "$G" -p "$PID" -t "$APP_MEASURE_S" \
      | tee "$PF" >/dev/null || warn "Group $G failed"
  else
    likwid-perfctr -C "$CORES" -g "$G" -p "$PID" -t "$APP_MEASURE_S" \
      | tee "$PF" >/dev/null || warn "Group $G failed"
  fi
}

measure_group "$G_MEM"
measure_group "$G_L3"
measure_group "$G_L2"
measure_group "$G_L1"
measure_group "$G_CPI"

# -------------------------- step G: compute intensity & summary ----------------
BW_MEM="$(get_mem_bw_sum "$OUT/app/${G_MEM}.out" || true)"
BW_L3="$( [ -n "$G_L3" ] && get_mem_bw_sum "$OUT/app/${G_L3}.out" || true )"
BW_L2="$( [ -n "$G_L2" ] && get_mem_bw_sum "$OUT/app/${G_L2}.out" || true )"
BW_L1="$( [ -n "$G_L1" ] && get_mem_bw_sum "$OUT/app/${G_L1}.out" || true )"

INSTR="$(get_instructions_sum "$OUT/app/${G_CPI}.out" || true)"
RT_S="$(get_runtime_s "$OUT/app/${G_CPI}.out" || echo "$APP_MEASURE_S")"

if [[ -n "$INSTR" && -n "$RT_S" && -n "$BW_MEM" ]]; then
  INSTR_PER_S=$(awk -v i="$INSTR" -v t="$RT_S" 'BEGIN{ if(t>0) printf "%.3f", i/t; else print "" }')
  BYTES_PER_S=$(awk -v m="$BW_MEM" 'BEGIN{ printf "%.3f", m*1024*1024 }')   # MBytes/s -> Bytes/s
  INSTR_PER_BYTE=$(awk -v ips="$INSTR_PER_S" -v bps="$BYTES_PER_S" 'BEGIN{ if(bps>0) printf "%.9f", ips/bps; else print "" }')
else
  warn "Could not compute intensity (missing CPI or MEM numbers)"
  INSTR_PER_S=""
  INSTR_PER_BYTE=""
fi

# Try to pull ‘roof’ peaks (last numbers in each output). We don’t force-parse—keep raw too.
roof_pick() {
  local f="$1"; awk '/MByte\/s|MBytes\/s/ {val=$NF} END{ if(val!="") print val }' "$f" 2>/dev/null || true
}
ROOF_L1="$(roof_pick "$OUT/roofs/L1.out")"
ROOF_L2="$(roof_pick "$OUT/roofs/L2.out")"
ROOF_L3="$(roof_pick "$OUT/roofs/L3.out")"
ROOF_MEM="$(roof_pick "$OUT/roofs/MEM.out")"

# Write a compact CSV summary
CSV="$OUT/roofline_summary.csv"
{
  echo "metric,value,unit,notes"
  echo "app_mem_bandwidth,$BW_MEM,MBytes/s,LIKWID MEM SUM"
  [ -n "$BW_L3" ] && echo "app_l3_bandwidth,$BW_L3,MBytes/s,LIKWID $G_L3 SUM"
  [ -n "$BW_L2" ] && echo "app_l2_bandwidth,$BW_L2,MBytes/s,LIKWID $G_L2 SUM"
  [ -n "$BW_L1" ] && echo "app_l1_bandwidth,$BW_L1,MBytes/s,LIKWID $G_L1 SUM"
  [ -n "$INSTR" ] && echo "app_instructions,$INSTR,count,LIKWID $G_CPI (INSTR_RETIRED_ANY)"
  [ -n "$RT_S" ] && echo "app_runtime,$RT_S,s,From $G_CPI Runtime RDTSC"
  [ -n "$INSTR_PER_S" ] && echo "app_instr_per_sec,$INSTR_PER_S,1/s,Derived"
  [ -n "$INSTR_PER_BYTE" ] && echo "app_instr_per_byte,$INSTR_PER_BYTE,1/byte,Instruction Roofline intensity"
  [ -n "$ROOF_L1" ] && echo "roof_L1,$ROOF_L1,MBytes/s,likwid-bench load_avx ${SZS[L1]} ${THREADS}t"
  [ -n "$ROOF_L2" ] && echo "roof_L2,$ROOF_L2,MBytes/s,likwid-bench load_avx ${SZS[L2]} ${THREADS}t"
  [ -n "$ROOF_L3" ] && echo "roof_L3,$ROOF_L3,MBytes/s,likwid-bench load_avx ${SZS[L3]} ${THREADS}t"
  [ -n "$ROOF_MEM" ] && echo "roof_MEM,$ROOF_MEM,MBytes/s,likwid-bench copy_avx ${SZS[MEM]} ${THREADS}t"
} > "$CSV"

log "Summary CSV: $CSV"
log "Raw outputs:"
log "  Roofs: $OUT/roofs/*.out"
log "  App:   $OUT/app/{${G_MEM},${G_L3:-},${G_L2:-},${G_L1:-},${G_CPI}}.out"
log "Bench log: $LOG_BENCH"

# Let the bench finish if still running (but don’t fail if it already ended)
if ps -p "$BENCH_PID" >/dev/null 2>&1; then
  log "Waiting for BenchBase runner (pid=$BENCH_PID) to finish…"
  wait "$BENCH_PID" || true
fi

log "All done."
