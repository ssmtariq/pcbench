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

# -------- paths & constants --------------------------------------------------
WARMUP_CONFIG="$HOME/benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_small.xml"
MEASURE_CONFIG="$HOME/benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_large.xml"
BB_JAR="$HOME/benchbase/target/benchbase-postgres/benchbase.jar"
PGDATA="$HOME/pgdata"

ITERATIONS=10
SAMPLE_INTERVAL=5

TMPDIR="$(mktemp -d)"
THR_FILE="$TMPDIR/throughputs.txt"
RESULTS_FILE="$HOME/tpcc_bench_results.log"   # <-- final report file

log "Workspace      : $TMPDIR"
log "Warmup config  : $WARMUP_CONFIG"
log "Measure config : $MEASURE_CONFIG"
log "JAR            : $BB_JAR"

# -------- 1. one-time load (use LARGE so dataset matches measured runs) ------
log "Step 1/3  – one-time schema+data load (no execution)"
/usr/bin/java   -jar "$BB_JAR" \
                -b tpcc \
                -c "$MEASURE_CONFIG" \
                --create=true --load=true --execute=false

# -------- 2. benchmark loop --------------------------------------------------
log "Step 2/3  – starting $ITERATIONS timed runs"
for i in $(seq 1 "$ITERATIONS"); do
  log "Run $i/$ITERATIONS – fast restart of PostgreSQL"
  pg_ctl -D "$PGDATA" restart -m fast
  sleep 5

  # ---- 2a) warmup: 30–60s using SMALL config; discard metrics --------------
  # (xl170_tpcc_small.xml already has <time>60</time>.)
  WLOG="$TMPDIR/warmup_${i}.log"
  log "Run $i/$ITERATIONS – warmup execute (discarding metrics)"
  /usr/bin/java -jar "$BB_JAR" \
       -b tpcc \
       -c "$WARMUP_CONFIG" \
       --create=false --load=false --execute=true \
       -s "$SAMPLE_INTERVAL" | tee "$WLOG" >/dev/null

  # ---- 2b) measured run using LARGE config ---------------------------------
  LOG="$TMPDIR/run_${i}.log"
  log "Run $i/$ITERATIONS – measured execute (sampling ${SAMPLE_INTERVAL}s)"
  /usr/bin/java -jar "$BB_JAR" \
       -b tpcc \
       -c "$MEASURE_CONFIG" \
       --create=false --load=false --execute=true \
       -s "$SAMPLE_INTERVAL" | tee "$LOG"

  # ---- extract throughput ---------------------------------------------------
#   tp=$(grep -oP '= \K[0-9.]+(?= requests/sec \(throughput\))' "$LOG" | tail -n1)
tp=$(grep -oP '= \K[0-9.]+(?= requests/sec \(throughput\))' "$LOG" \
     | awk '{n++; s+=$1} END{ if(n==0){exit 1} printf "%.6f", s/n }')
  if [[ -z "$tp" ]]; then
    fatal "Throughput not found in $LOG"
  fi
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
    printf "%.6f %.6f", mean, sqrt(var)
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
  echo "Runs  : $run_list"
  echo "Mean  : $mean"
  echo "Median: $median"
  echo "StdDev: $stdev"
} >> "$RESULTS_FILE"

log "Appended summary to $RESULTS_FILE"
