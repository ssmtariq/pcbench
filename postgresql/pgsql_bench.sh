#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# BenchBase TPCC repeat-runner with warmup + detailed logging + median TPS report
# Workload runner v2 has the same benchmarking features exept warmup and TPS calculation
# -----------------------------------------------------------------------------
set -Eeuo pipefail
shopt -s inherit_errexit        # traps ERR even in subshells

# -------- logging helpers ----------------------------------------------------
log()   { printf '\n[%s] %s\n'  "$(date '+%F %T')"  "$*"; }
fatal() { printf '\n❌  %s\n'   "$*" >&2; exit 1; }
trap 'fatal "Command \"${BASH_COMMAND}\" failed (line ${LINENO})"' ERR

# -------- ensure benchbase database exists ----------------------------------
log "Ensuring 'benchbase' database exists"
if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname='benchbase'" | grep -q 1; then
  log "Database 'benchbase' not found → creating"
  createdb benchbase
else
  log "Database 'benchbase' already exists"
fi

# -------- paths & constants --------------------------------------------------
# Source workloads directory (renamed from SRC_DIR per request) -> BenchBase config dir
WORKLOAD_DIR="$HOME/pcbench/postgresql/workload"
DEST_DIR="$HOME/benchbase/target/benchbase-postgres/config/postgres"

# Ensure BenchBase's expected config symlink exists (for config/plugin.xml)
CONFIG_ROOT="$HOME/benchbase/target/benchbase-postgres/config"
[[ -e "$HOME/config" ]] || ln -s "$CONFIG_ROOT" "$HOME/config"

# Ensure BenchBase config dir exists and copy XMLs as requested
mkdir -p "$DEST_DIR"
cp -f "$WORKLOAD_DIR/xl170_tpcc_small.xml" "$DEST_DIR/xl170_tpcc_small.xml"
cp -f "$WORKLOAD_DIR/xl170_tpcc_large.xml" "$DEST_DIR/xl170_tpcc_large.xml"

WARMUP_CONFIG="$HOME/benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_small.xml"
MEASURE_CONFIG_SMALL="$HOME/benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_small.xml"
MEASURE_CONFIG_LARGE="$HOME/benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_large.xml"

BB_JAR="$HOME/benchbase/target/benchbase-postgres/benchbase.jar"
PGDATA="$HOME/pgdata"

# -------- defaults (updated per request) ------------------------------------
# Default behavior: NO warmup + SMALL load + 1 iteration
WARMUP="${WARMUP:-0}"                  # 0 = no warmup (default), 1 = do a small warmup run each iteration
WORKLOAD="${WORKLOAD:-small}"          # "small" (default) or "large" measured runs
ITERATIONS="${ITERATIONS:-1}"          # default single run
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"

# Derived measured config based on WORKLOAD
if [[ "$WORKLOAD" == "large" ]]; then
  MEASURE_CONFIG="$MEASURE_CONFIG_LARGE"
else
  MEASURE_CONFIG="$MEASURE_CONFIG_SMALL"
fi

TMPDIR="$(mktemp -d)"
THR_FILE="$TMPDIR/throughputs.txt"
RESULTS_FILE="${RESULTS_FILE:-$HOME/tpcc_bench_results.log}"

log "Workspace      : $TMPDIR"
log "Warmup?        : $([[ "$WARMUP" == "1" ]] && echo yes || echo no)"
log "Measured size  : $WORKLOAD"
log "Warmup config  : $WARMUP_CONFIG"
log "Measure config : $MEASURE_CONFIG"
log "JAR            : $BB_JAR"

# -------- 1. one-time schema+data load (match measured size) ----------------
LOAD_CONFIG="$MEASURE_CONFIG"
log "Step 1/3  – one-time schema+data load using: $LOAD_CONFIG"
/usr/bin/java   -jar "$BB_JAR" \
                -b tpcc \
                -c "$LOAD_CONFIG" \
                --create=true --load=true --execute=false

# -------- 2. benchmark loop --------------------------------------------------
log "Step 2/3  – starting $ITERATIONS timed run(s)"
for i in $(seq 1 "$ITERATIONS"); do
  log "Run $i/$ITERATIONS – fast restart of PostgreSQL"
  pg_ctl -D "$PGDATA" restart -m fast
  sleep 5

  # ---- 2a) optional warmup (SMALL) -----------------------------------------
  if [[ "$WARMUP" == "1" ]]; then
    WLOG="$TMPDIR/warmup_${i}.log"
    log "Run $i/$ITERATIONS – warmup execute (SMALL; discard metrics)"
    /usr/bin/java -jar "$BB_JAR" \
         -b tpcc \
         -c "$WARMUP_CONFIG" \
         --create=false --load=false --execute=true \
         -s "$SAMPLE_INTERVAL" | tee "$WLOG" >/dev/null
  else
    log "Run $i/$ITERATIONS – skipping warmup"
  fi

  # ---- 2b) measured run (SMALL or LARGE per WORKLOAD) ----------------------
  LOG="$TMPDIR/run_${i}.log"
  log "Run $i/$ITERATIONS – measured execute (sampling ${SAMPLE_INTERVAL}s)"
  /usr/bin/java -jar "$BB_JAR" \
       -b tpcc \
       -c "$MEASURE_CONFIG" \
       --create=false --load=false --execute=true \
       -s "$SAMPLE_INTERVAL" | tee "$LOG"

  # ---- extract throughput (mean of per-sample lines) -----------------------
  tp=$(grep -oP '= \K[0-9.]+(?= requests/sec \(throughput\))' "$LOG" \
       | awk '{n++; s+=$1} END{ if(n==0){exit 1} printf "%.6f", s/n }') || fatal "Throughput not found in $LOG"

  printf '%s\n' "$tp" >> "$THR_FILE"
  log "Run $i/$ITERATIONS – throughput = $tp TPS"
done

# -------- 3. report ----------------------------------------------------------
log "Step 3/3  – results"

echo -e "\n────────── TPS per run ──────────"
nl -ba "$THR_FILE"

sorted=$(sort -n "$THR_FILE")
count=$(wc -l < "$THR_FILE")

if (( count % 2 )); then
  median=$(echo "$sorted" | awk "NR == ($count + 1) / 2")
else
  median=$(echo "$sorted" | awk "NR==$count/2 || NR==$count/2+1" | awk '{s+=$1} END{print s/2}')
fi

read mean stdev <<<"$(awk '
  {n++; sum += $1; sumsq += ($1)^2}
  END {
    mean  = sum / n
    var   = (n > 1) ? (sumsq - sum*sum/n)/(n-1) : 0
    printf "%f %f", mean, sqrt(var)
  }
' "$THR_FILE")"

echo -e "─────────────────────────────────"
echo   "Median TPS : $median"
echo   "Mean TPS   : $mean"
echo   "Std-Dev TPS: $stdev"
echo   "All logs & intermediate files are in $TMPDIR"

timestamp=$(date '+%A, %d %B %Y %T')
run_list=$(paste -sd, "$THR_FILE" | sed 's/,/, /g')

{
  echo '---'
  echo "$timestamp"
  echo "Warmup? : $([[ "$WARMUP" == "1" ]] && echo yes || echo no)"
  echo "Size    : $WORKLOAD"
  echo "Runs  : $run_list"
  echo "Mean  : $mean"
  echo "Median: $median"
  echo "StdDev: $stdev"
} >> "$RESULTS_FILE"

log "Appended summary to $RESULTS_FILE"
