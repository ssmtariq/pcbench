#!/usr/bin/env bash
# LIKWID Roofline for PostgreSQL + BenchBase (xl170/Ubuntu 22.04)
# - Uses your existing pgsql_bench.sh to drive TPCC
# - Measures L1/L2/L3/memory bandwidth roofs (likwid-bench)
# - Attaches to a running Postgres backend PID (application_name='tpcc') to get app point
# - Parsing + CSV writing delegated to parser.sh

###############################################################################
# Minimal-Change Modular Refactor
# - Wrapped original logic into small functions (pipeline stages).
# - Introduced a SUT adapter with PostgreSQL-specific hooks.
# - Kept comments and commands intact; no logic changes beyond function wiring.
###############################################################################

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

# ---- knobs to match kernel R/W patterns (defaults preserve behavior) ----
ROOF_KERNEL_CACHE="${ROOF_KERNEL_CACHE:-load_avx}"   # e.g., load_avx | stream_avx
ROOF_KERNEL_MEM="${ROOF_KERNEL_MEM:-copy_avx}"       # e.g., copy_avx | stream_avx | triad_avx
PEAK_WS="${PEAK_WS:-20kB}"                           # peakflops WS, should fit L1
# Optional: MAX_IPC for instr/s roof estimate (fallback used in parser if unset)
MAX_IPC="${MAX_IPC:-}"

# -------------------------- sanity checks --------------------------------------
ensure_prereqs() {
  need likwid-perfctr
  need likwid-bench
  need psql
  [ -x "$BENCH_SCRIPT" ] || fatal "Bench script not found or not executable: $BENCH_SCRIPT"

  sudo modprobe msr 2>/dev/null || true
  if [ -w /proc/sys/kernel/perf_event_paranoid ]; then
    echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null 2>&1 || true
  fi
  export LIKWID_PERF_GROUPS="${LIKWID_PERF_GROUPS:-/usr/share/likwid/perfgroups}"
}

# -------------------------- result workspace -----------------------------------
prepare_workspace() {
  TS="$(date '+%Y%m%d-%H%M%S')"
  OUT="$RESULT_ROOT/$TS"
  mkdir -p "$OUT"/{roofs,app,logs}
  log "Results directory: $OUT"

  THREADS_ROOFS="$(corespec_count "${CORES:-}")"
  [ -z "$THREADS_ROOFS" ] && THREADS_ROOFS=1
  log "Roof measurements will use THREADS=$THREADS_ROOFS to match CORES=$CORES"
}

# -------------------------- step A: roofs --------------------------------------
measure_or_hydrate_roofs() {
  log "Step A: Measuring roof bandwidths with likwid-bench (THREADS=$THREADS_ROOFS)"
  declare -gA SZS
  declare -Ag SZS=( ["L1"]="32kB" ["L2"]="256kB" ["L3"]="2MB" ["MEM"]="2GB" )

  # We store summary CSV and raw *.out so later runs can hydrate $OUT/roofs/ without recompute.
  # CSV schema:
  # node_sig,threads_roofs,kernel_cache,kernel_mem,ws_L1,ws_L2,ws_L3,ws_MEM,l1_bw_mb_s,l2_bw_mb_s,l3_bw_mb_s,mem_bw_mb_s,peak_value,peak_unit,timestamp
  _node_sig="$( (hostnamectl 2>/dev/null || true) | awk -F: '
    /Static hostname|Hardware Vendor|Hardware Model/{
      gsub(/^[[:space:]]+/, "", $2); printf "%s|", $2
    } END{print ""}' )"
  [ -n "$_node_sig" ] || _node_sig="$(printf "%s|%s|%s\n" \
    "$(hostname 2>/dev/null || echo unknown-host)" \
    "$(lscpu 2>/dev/null | awk -F: "/Model name/{gsub(/^[[:space:]]+/,\"\",$2);print $2; exit}")" \
    "$(lscpu 2>/dev/null | awk -F: "/Architecture/{gsub(/^[[:space:]]+/,\"\",$2);print $2; exit}")")"
  CACHE_NODE="$(echo "$_node_sig" | tr ' /:' '___')"
  ROOF_CSV="${SCRIPT_DIR}/.rooflines_${CACHE_NODE}.csv"
  RAW_CACHE_DIR="${SCRIPT_DIR}/.roofcache_${CACHE_NODE}"
  mkdir -p "$RAW_CACHE_DIR"

  ROOFS_READY=""
  if [ -s "$ROOF_CSV" ] && [ -s "$RAW_CACHE_DIR/L1.out" ] && [ -s "$RAW_CACHE_DIR/L2.out" ] \
     && [ -s "$RAW_CACHE_DIR/L3.out" ] && [ -s "$RAW_CACHE_DIR/MEM.out" ] \
     && [ -s "$RAW_CACHE_DIR/PEAKFLOPS.out" ]; then
    log "  Found cached roofline CSV for this node → $ROOF_CSV"
    cp "$RAW_CACHE_DIR"/{L1.out,L2.out,L3.out,MEM.out,PEAKFLOPS.out} "$OUT/roofs/" 2>/dev/null || true
    ROOFS_READY=1
  fi

  for LVL in L1 L2 L3 MEM; do
    OUTF="$OUT/roofs/${LVL}.out"
    # Skip measurement if cache is ready; ensure the file exists in $OUT/roofs/
    if [ -n "${ROOFS_READY:-}" ]; then
      log "  Roof $LVL: using cached raw → $OUTF"
      continue
    fi
    if [ "$LVL" = "MEM" ]; then
      log "  Roof MEM: likwid-bench -t ${ROOF_KERNEL_MEM} -W N:${SZS[$LVL]}:${THREADS_ROOFS}"
      likwid-bench -t "${ROOF_KERNEL_MEM}" -W "N:${SZS[$LVL]}:${THREADS_ROOFS}" | tee "$OUTF" >/dev/null
    else
      log "  Roof $LVL: likwid-bench -t ${ROOF_KERNEL_CACHE} -W N:${SZS[$LVL]}:${THREADS_ROOFS}"
      likwid-bench -t "${ROOF_KERNEL_CACHE}" -W "N:${SZS[$LVL]}:${THREADS_ROOFS}" | tee "$OUTF" >/dev/null
    fi
  done

  # ---- FP compute roof (flat) via peakflops_avx_fma (optional, but on by default) ----
  PEAKF="$OUT/roofs/PEAKFLOPS.out"
  # If cached, skip measuring peakflops
  if [ -n "${ROOFS_READY:-}" ]; then
    log "  Peak FP roof: using cached raw → $PEAKF"
  else
    log "  Peak FP roof: likwid-bench -t peakflops_avx_fma -W N:${PEAK_WS}:${THREADS}"
    likwid-bench -t peakflops_avx_fma -W "N:${PEAK_WS}:${THREADS}" | tee "$PEAKF" >/dev/null
  fi

  log "  Roof measurements saved to $OUT/roofs/"

  # Write / update per-node CSV and persist raw *.out into the raw cache (first-run only)
  if [ -z "${ROOFS_READY:-}" ]; then
    # helper to extract last numeric on a line containing MByte/s (robust across formats)
    get_bw_mb_s() { grep -E 'MByte/s' "$1" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) v=$i} END{print v}'; }
    # peakflops often reports MFLOP/s or GFLOP/s; capture value + unit
    get_peak_val() {
      grep -E 'M?G?FLOP[S]?/s' "$1" | awk '{
        val=""; unit="";
        for(i=1;i<=NF;i++){
          if($i ~ /^[0-9.]+$/) val=$i;
          if($i ~ /(MFLOP\/s|GFLOP\/s|MFLOPS\/s|GFLOP\/s|MFLOP\/S|GFLOP\/S|MFLOPS|GFLOPS)/){unit=$i}
        }
        if(val!=""){print val"|"unit}
      }' | tail -n 1 || true
    }
    L1_BW="$(get_bw_mb_s "$OUT/roofs/L1.out")"
    L2_BW="$(get_bw_mb_s "$OUT/roofs/L2.out")"
    L3_BW="$(get_bw_mb_s "$OUT/roofs/L3.out")"
    MEM_BW="$(get_bw_mb_s "$OUT/roofs/MEM.out")"
    PEAK_PAIR="$(get_peak_val "$PEAKF")" || true
    PEAK_VAL="${PEAK_PAIR%%|*}"
    PEAK_UNIT="${PEAK_PAIR##*|}"
    # Write CSV header if absent, then write/overwrite single-line record for this node
    if [ ! -s "$ROOF_CSV" ]; then
      printf '%s\n' "node_sig,threads_roofs,kernel_cache,kernel_mem,ws_L1,ws_L2,ws_L3,ws_MEM,l1_bw_mb_s,l2_bw_mb_s,l3_bw_mb_s,mem_bw_mb_s,peak_value,peak_unit,timestamp" > "$ROOF_CSV"
    fi
    # Overwrite the CSV to keep one canonical record per node
    tmpcsv="$(mktemp)"
    printf '%s\n' "node_sig,threads_roofs,kernel_cache,kernel_mem,ws_L1,ws_L2,ws_L3,ws_MEM,l1_bw_mb_s,l2_bw_mb_s,l3_bw_mb_s,mem_bw_mb_s,peak_value,peak_unit,timestamp" > "$tmpcsv"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$_node_sig" "$THREADS_ROOFS" "$ROOF_KERNEL_CACHE" "$ROOF_KERNEL_MEM" \
      "${SZS[L1]}" "${SZS[L2]}" "${SZS[L3]}" "${SZS[MEM]}" \
      "${L1_BW:-}" "${L2_BW:-}" "${L3_BW:-}" "${MEM_BW:-}" \
      "${PEAK_VAL:-}" "${PEAK_UNIT:-}" "$(date -u +'%F %T UTC')" >> "$tmpcsv"
    mv "$tmpcsv" "$ROOF_CSV"
    # persist raw files for lossless hydration next time
    cp "$OUT/roofs"/{L1.out,L2.out,L3.out,MEM.out,PEAKFLOPS.out} "$RAW_CACHE_DIR"/ 2>/dev/null || true
  fi
}

# -------------------------- SUT adapter: PostgreSQL -----------------------------
sut_start_bench() {
  # -------------------------- step B: start BenchBase ----------------------------
  log "Step B: Launching your BenchBase run via $BENCH_SCRIPT (WORKLOAD=$WORKLOAD, WARMUP=$WARMUP, ITERATIONS=$ITERATIONS)"
  LOG_BENCH="$OUT/logs/bench_run.log"
  ( WARMUP="$WARMUP" WORKLOAD="$WORKLOAD" ITERATIONS="$ITERATIONS" bash "$BENCH_SCRIPT" ) |& tee "$LOG_BENCH" &
  BENCH_PID=$!
  log "BenchBase runner PID: $BENCH_PID"
}

sut_find_backend_pid_initial() {
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
}

sut_pin_backend_pid() {
  # -------------------------- step D: optional pin -------------------------------
  if [ -n "${CORES}" ]; then
    log "Pinning backend $PID to cores: $CORES"
    sudo taskset -pc "$CORES" "$PID" >/dev/null || warn "taskset pin failed; continuing"
  else
    CURR_CORE="$(ps -o psr= -p "$PID" | awk '{print $1}')"
    CORES="$CURR_CORE"
    log "No CORES provided; measuring on current core: $CORES"
  fi

  # ---- NUMA breadcrumbs (no behavior change) ----
  {
    echo "# numactl --hardware"
    numactl --hardware 2>&1 || true
    echo
    echo "# backend /proc/${PID}/numa_maps (first 50 lines)"
    head -n 50 "/proc/${PID}/numa_maps" 2>&1 || true
  } > "$OUT/logs/numa_backend.txt"
}

sut_detect_groups() {
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
}

sut_wait_for_measured_phase() {
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
  wait_for_measured_phase
}

sut_refresh_backend_and_pin() {
  refresh_backend_and_pin() {
    sleep 1
    local newpid=""
    for _ in $(seq 1 120); do
      newpid="$(psql -tAc "
        SELECT pid
        FROM pg_stat_activity
        WHERE application_name='tpcc'
          AND backend_type='client backend'
          AND state='active'
          AND wait_event IS NULL
        ORDER BY xact_start DESC NULLS LAST, state_change DESC, backend_start DESC
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
  refresh_backend_and_pin
}

sut_measure_groups() {
  # -------------------------- step F: measure app point --------------------------
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
}

sut_parse_and_summarize() {
  # -------------------------- step G: parse + write summary ----------------------
  CSV_PATH="$(roofline_parse_and_write \
    "$OUT" "$G_MEM" "$G_CPI" "$G_CACHES" "$G_L3" "$G_L2" "$G_L1" \
    "$APP_MEASURE_S" "$THREADS" "${SZS[L1]}" "${SZS[L2]}" "${SZS[L3]}" "${SZS[MEM]}" \
    "$CORES" "$MAX_IPC" "$ROOF_KERNEL_CACHE" "$ROOF_KERNEL_MEM" "$PEAK_WS")"

  log "Summary CSV: ${CSV_PATH:-$OUT/roofline_summary.csv}"
  log "Raw outputs:"
  log "  Roofs: $OUT/roofs/*.out"
  log "  App:   $OUT/app/{${G_MEM},${G_L3:-},${G_L2:-},${G_L1:-},${G_CPI}}.out"
  log "  NUMA:  $OUT/logs/numa_backend.txt"
  log "Bench log: $LOG_BENCH"

  if ps -p "$BENCH_PID" >/dev/null 2>&1; then
    log "Waiting for BenchBase runner (pid=$BENCH_PID) to finish…"
    wait "$BENCH_PID" || true
  fi

  log "All done."
}

# -------------------------- Main pipeline --------------------------------------
main() {
  ensure_prereqs
  prepare_workspace
  measure_or_hydrate_roofs
  sut_start_bench
  sut_find_backend_pid_initial
  sut_pin_backend_pid
  sut_detect_groups
  sut_wait_for_measured_phase
  sut_refresh_backend_and_pin
  sut_measure_groups
  sut_parse_and_summarize
}

main "$@"
