#!/usr/bin/env bash
# LIKWID Roofline for PostgreSQL + BenchBase (xl170/Ubuntu 22.04)
# - Uses your existing pgsql_bench.sh to drive TPCC
# - Measures L1/L2/L3/memory bandwidth roofs (likwid-bench)
# - Attaches to a running Postgres backend PID (application_name='tpcc') to get app point
# - Parsing + CSV writing delegated to parser.sh

set -Eeuo pipefail
shopt -s inherit_errexit

# -------------------------- logging and guards ---------------------------------
log()   { printf '\n[%s] %s\n'  "$(date '+%F %T')" "$*"; }
warn()  { printf '\n⚠️  %s\n'  "$*" >&2; }
fatal() { printf '\n❌ %s\n'   "$*" >&2; exit 1; }
dbg()   { printf '[DEBUG] %s\n' "$*" >&2; }
trap 'fatal "Command \"${BASH_COMMAND}\" failed (line ${LINENO})"' ERR

need()  { command -v "$1" >/dev/null 2>&1 || fatal "Missing dependency: $1"; }

export LC_ALL=C
export LANG=C

# -------------------------- inputs / defaults ----------------------------------
WARMUP="${WARMUP:-1}"           # 0|1
WORKLOAD="${WORKLOAD:-small}"   # small|large|xl
ITERATIONS="${ITERATIONS:-1}"

APP_MEASURE_S="${APP_MEASURE_S:-45}"
THREADS="${THREADS:-$(nproc)}"
CORES="${CORES:-}"
RESULT_ROOT="${RESULT_ROOT:-$HOME/likwid_roofline}"
BENCH_SCRIPT="${BENCH_SCRIPT:-$HOME/pcbench/postgresql/pgsql_bench.sh}"

# Path to parser helper (can override via PARSER_LIB)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_LIB="${PARSER_LIB:-${SCRIPT_DIR}/parser.sh}"
[ -r "$PARSER_LIB" ] || fatal "Parser helper not found: $PARSER_LIB"
# shellcheck source=/dev/null
source "$PARSER_LIB"

# -------------------------- sanity checks --------------------------------------
need likwid-perfctr
need likwid-bench
need psql
[ -x "$BENCH_SCRIPT" ] || fatal "Bench script not found or not executable: $BENCH_SCRIPT"

sudo modprobe msr 2>/dev/null || true
if [ -w /proc/sys/kernel/perf_event_paranoid ]; then
  echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null 2>&1 || true
fi
export LIKWID_PERF_GROUPS="${LIKWID_PERF_GROUPS:-/usr/share/likwid/perfgroups}"

# -------------------------- result workspace -----------------------------------
TS="$(date '+%Y%m%d-%H%M%S')"
OUT="$RESULT_ROOT/$TS"
mkdir -p "$OUT"/{roofs,app,logs}
log "Results directory: $OUT"

# -------------------------- step A: roofs --------------------------------------
log "Step A: Measuring roof bandwidths with likwid-bench (THREADS=$THREADS)"
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
log "  Roof measurements saved to $OUT/roofs/"

# -------------------------- step B: start BenchBase ----------------------------
log "Step B: Launching your BenchBase run via $BENCH_SCRIPT (WORKLOAD=$WORKLOAD, WARMUP=$WARMUP, ITERATIONS=$ITERATIONS)"
LOG_BENCH="$OUT/logs/bench_run.log"
( WARMUP="$WARMUP" WORKLOAD="$WORKLOAD" ITERATIONS="$ITERATIONS" bash "$BENCH_SCRIPT" ) |& tee "$LOG_BENCH" &
BENCH_PID=$!
log "BenchBase runner PID: $BENCH_PID"

# -------------------------- step C: find backend PID ---------------------------
log "Step C: Waiting for a PostgreSQL backend with application_name='tpcc' ..."
PID=""
for _ in $(seq 1 120); do
  PID="$(psql -tAc "SELECT pid FROM pg_stat_activity WHERE application_name='tpcc' AND state <> 'idle' ORDER BY backend_start DESC LIMIT 1;" 2>/dev/null | tr -d ' ')"
  [ -n "$PID" ] && break
  sleep 1
done
[ -z "$PID" ] && fatal "Could not find a Postgres backend for application_name='tpcc'. Is BenchBase running?"
log "Found backend PID: $PID"

# -------------------------- step D: optional pin -------------------------------
if [ -n "${CORES}" ]; then
  log "Pinning backend $PID to cores: $CORES"
  sudo taskset -pc "$CORES" "$PID" >/dev/null || warn "taskset pin failed; continuing"
else
  CURR_CORE="$(ps -o psr= -p "$PID" | awk '{print $1}')"
  CORES="$CURR_CORE"
  log "No CORES provided; measuring on current core: $CORES"
fi

# -------------------------- step E: detect groups ------------------------------
GROUPS_LIST="$(likwid-perfctr -a 2>/dev/null | sed 's/^[[:space:]]*//')"
pick_group() { grep -q "^$1[[:space:]]" <<<"$GROUPS_LIST" && echo "$1" || true; }

G_L1="$(pick_group L1D)"; [ -z "$G_L1" ] && G_L1="$(pick_group L1CACHE)"
G_L2="$(pick_group L2)";  [ -z "$G_L2" ] && G_L2="$(pick_group L2CACHE)"
G_L3="$(pick_group L3)";  [ -z "$G_L3" ] && G_L3="$(pick_group L3CACHE)"
G_MEM="MEM"

pick_cpi_group() {
  if grep -q "^CPI[[:space:]]"    <<<"$GROUPS_LIST"; then echo "CPI";    return; fi
  if grep -q "^TMA[[:space:]]"    <<<"$GROUPS_LIST"; then echo "TMA";    return; fi
  if grep -q "^CACHES[[:space:]]" <<<"$GROUPS_LIST"; then echo "CACHES"; return; fi
  echo ""
}
G_CPI="$(pick_cpi_group)"
G_CACHES="$(pick_group CACHES)"

log "Detected groups -> L1=${G_L1:-N/A}, L2=${G_L2:-N/A}, L3=${G_L3:-N/A}, MEM=$G_MEM, CPI=${G_CPI:-N/A}, CACHES=${G_CACHES:-N/A}"

wait_for_measured_phase() {
  log "Waiting for BenchBase measured phase marker in $LOG_BENCH"
  local pat='MEASURE :: Warmup complete, starting measurements|Run 1/1 .* measured execute'
  ( timeout 15m bash -c "tail -n +1 -F \"$LOG_BENCH\" | grep -E -m1 \"$pat\"" ) & local wpid=$!
  if ! wait "$wpid"; then
    warn "Timed out waiting for measured phase marker in $LOG_BENCH"
  else
    log "Measured phase detected."
  fi
}

refresh_backend_and_pin() {
  sleep 1
  local newpid=""
  for _ in $(seq 1 120); do
    newpid="$(psql -tAc "
      SELECT pid
      FROM pg_stat_activity
      WHERE application_name='tpcc'
        AND state IN ('active','fastpath function call','idle in transaction','idle in transaction (aborted)')
      ORDER BY backend_start DESC
      LIMIT 1;
    " 2>/dev/null | tr -d ' ')"
    [ -n "$newpid" ] && break
    sleep 0.5
  done
  if [ -z "$newpid" ]; then
    warn "Could not find a live tpcc backend after measured phase started"
  else
    PID="$newpid"
    log "Re-acquired backend PID: $PID"
    if [ -n "${CORES}" ]; then
      log "Re-pinning backend $PID to cores: $CORES"
      sudo taskset -pc "$CORES" "$PID" >/dev/null || warn "taskset pin failed; continuing"
    else
      CURR_CORE="$(ps -o psr= -p "$PID" | awk '{print $1}')"
      CORES="$CURR_CORE"
      log "No CORES provided; measuring on current core: $CORES"
    fi
  fi
}

# -------------------------- step F: measure app point --------------------------
wait_for_measured_phase
refresh_backend_and_pin
export LIKWID_PERF_PID="$PID"

measure_group() {
  local G="$1"; local PF="$OUT/app/${G}.out"
  [ -z "$G" ] && return 0
  log "Measuring group $G for ${APP_MEASURE_S}s on cores $CORES (backend pinned)"
  if [ "$(id -u)" -ne 0 ]; then
    sudo -E likwid-perfctr -f -C "$CORES" -g "$G" -- sleep "$APP_MEASURE_S" \
      | tee "$PF" >/dev/null || warn "Group $G failed"
  else
    likwid-perfctr -f -C "$CORES" -g "$G" -- sleep "$APP_MEASURE_S" \
      | tee "$PF" >/dev/null || warn "Group $G failed"
  fi
}

measure_group "$G_MEM"
measure_group "$G_CPI"
measure_group "$G_CACHES"
measure_group "$G_L3"
measure_group "$G_L2"
measure_group "$G_L1"

# If chosen CPI group lacks CPI/IPC, try plain 'CPI'
if [ -s "$OUT/app/${G_CPI}.out" ]; then
  test_cpi="$(get_cpi "$OUT/app/${G_CPI}.out")"
  test_ipc="$(get_ipc "$OUT/app/${G_CPI}.out")"
  if [ -z "$test_cpi" ] && [ -z "$test_ipc" ]; then
    if grep -q "^CPI[[:space:]]" <<<"$GROUPS_LIST"; then
      measure_group "CPI"
      [ -s "$OUT/app/CPI.out" ] && G_CPI="CPI"
    fi
  fi
fi

[ -s "$OUT/app/${G_MEM}.out" ] || warn "Missing LIKWID MEM output: $OUT/app/${G_MEM}.out"
[ -s "$OUT/app/${G_CPI}.out" ] || warn "Missing LIKWID $G_CPI output: $OUT/app/${G_CPI}.out"

# -------------------------- step G: parse + write summary ----------------------
CSV_PATH="$(roofline_parse_and_write "$OUT" "$G_MEM" "$G_CPI" "$G_CACHES" "$G_L3" "$G_L2" "$G_L1" "$APP_MEASURE_S" "$THREADS" "${SZS[L1]}" "${SZS[L2]}" "${SZS[L3]}" "${SZS[MEM]}")"

log "Summary CSV: ${CSV_PATH:-$OUT/roofline_summary.csv}"
log "Raw outputs:"
log "  Roofs: $OUT/roofs/*.out"
log "  App:   $OUT/app/{${G_MEM},${G_L3:-},${G_L2:-},${G_L1:-},${G_CPI}}.out"
log "Bench log: $LOG_BENCH"

if ps -p "$BENCH_PID" >/dev/null 2>&1; then
  log "Waiting for BenchBase runner (pid=$BENCH_PID) to finish…"
  wait "$BENCH_PID" || true
fi

log "All done."
