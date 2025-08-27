#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Redis repeat‑runner (YCSB) with warm‑up + median throughput report
#
# This script exercises a Redis instance using the Yahoo Cloud Serving
# Benchmark (YCSB).  It starts the server, loads a dataset, runs a brief
# warm‑up and then performs multiple measured runs.  Throughput values
# extracted from YCSB’s `[OVERALL], Throughput(ops/sec)` line are
# aggregated into median/mean/stddev and appended to a log file.
#
# The workload shape (record count, operation count, thread count and
# durations) defaults to the values used in TUNA’s ycsb.json【955028669945652†L1-L9】, but can
# be overridden via environment variables.
# -----------------------------------------------------------------------------
set -Eeuo pipefail
shopt -s inherit_errexit

log()   { printf '\n[%s] %s\n'  "$(date '+%F %T')"  "$*"; }
fatal() { printf '\n❌  %s\n'   "$*" >&2; exit 1; }
trap 'fatal "Command \"${BASH_COMMAND}\" failed (line ${LINENO})"' ERR

REDIS_SERVER=${REDIS_SERVER:-$(command -v redis-server || true)}
REDIS_CLI=${REDIS_CLI:-$(command -v redis-cli || true)}

# Location of YCSB installation.  By default the script expects YCSB
# to be unpacked or built under $HOME/YCSB.  Override YCSB_DIR to use
# another location.
YCSB_DIR=${YCSB_DIR:-$HOME/YCSB}
YCSB_BIN=${YCSB_BIN:-$YCSB_DIR/bin/ycsb.sh}

REDIS_CONF=${REDIS_CONF:-$HOME/pcbench/redis/configs/TUNA_best_redis_config.conf}
REDIS_PORT=${REDIS_PORT:-6379}
REDIS_HOST=${REDIS_HOST:-127.0.0.1}

# Workload parameters (can be overridden via env).  These mirror
# TUNA’s ycsb.json【955028669945652†L1-L9】.
WORKLOAD=${WORKLOAD:-workloada}
RECORDCOUNT=${RECORDCOUNT:-1800000}
OPERATIONCOUNT=${OPERATIONCOUNT:-2000000000}
THREADCOUNT=${THREADCOUNT:-40}
WARMUP_TIME=${WARMUP_TIME:-30}
MEASURE_TIME=${MEASURE_TIME:-300}
ITERATIONS=${ITERATIONS:-3}
TMPDIR="$(mktemp -d)"
THR_FILE="$TMPDIR/throughputs.txt"
RESULTS_FILE="${RESULTS_FILE:-$HOME/redis_bench_results.log}"

[[ -x "$REDIS_SERVER" ]] || fatal "redis-server not found; set REDIS_SERVER=/path/to/redis-server"
[[ -x "$YCSB_BIN" ]] || fatal "YCSB launcher not found; set YCSB_DIR to your YCSB installation"

start_redis() {
  log "Starting redis-server on $REDIS_HOST:$REDIS_PORT with $REDIS_CONF"
  "$REDIS_SERVER" "$REDIS_CONF" --port "$REDIS_PORT" --protected-mode no --daemonize yes
  sleep 1
}

stop_redis() {
  if [[ -x "$REDIS_CLI" ]]; then
    "$REDIS_CLI" -h "$REDIS_HOST" -p "$REDIS_PORT" shutdown nosave || true
  else
    pkill -f "redis-server.*:$REDIS_PORT" || true
  fi
  sleep 1
}

# Extract throughput (ops/sec) from YCSB run output.  YCSB prints a line like:
# [OVERALL], Throughput(ops/sec), 12345.678
extract_ops() {
  grep -i 'Throughput(ops/sec)' "$1" | tail -n1 | awk -F, '{gsub(/ /,"",$3); print $3}'
}

log "Workspace : $TMPDIR"
start_redis

# Load the dataset once before running experiments.  This populates the
# database with the specified number of records.
log "Loading initial dataset (recordcount=$RECORDCOUNT) into Redis via YCSB"
"$YCSB_BIN" load redis \
  -s -P "$YCSB_DIR/workloads/$WORKLOAD" \
  -p recordcount="$RECORDCOUNT" \
  -p operationcount="$OPERATIONCOUNT" \
  -p threadcount="$THREADCOUNT" \
  -p redis.host="$REDIS_HOST" \
  -p redis.port="$REDIS_PORT" \
  > "$TMPDIR/load.log" 2>&1

# Warm‑up run
log "Warm‑up for ${WARMUP_TIME}s"
"$YCSB_BIN" run redis \
  -s -P "$YCSB_DIR/workloads/$WORKLOAD" \
  -p recordcount="$RECORDCOUNT" \
  -p operationcount="$OPERATIONCOUNT" \
  -p threadcount="$THREADCOUNT" \
  -p maxexecutiontime="$WARMUP_TIME" \
  -p redis.host="$REDIS_HOST" \
  -p redis.port="$REDIS_PORT" \
  > "$TMPDIR/warmup.log" 2>&1 || true

log "Starting $ITERATIONS timed runs"
for i in $(seq 1 "$ITERATIONS"); do
  LOG="$TMPDIR/run_${i}.log"
  log "Run $i/$ITERATIONS – measure ${MEASURE_TIME}s"
  "$YCSB_BIN" run redis \
    -s -P "$YCSB_DIR/workloads/$WORKLOAD" \
    -p recordcount="$RECORDCOUNT" \
    -p operationcount="$OPERATIONCOUNT" \
    -p threadcount="$THREADCOUNT" \
    -p maxexecutiontime="$MEASURE_TIME" \
    -p redis.host="$REDIS_HOST" \
    -p redis.port="$REDIS_PORT" \
    > "$LOG" 2>&1

  tp=$(extract_ops "$LOG")
  [[ -n "$tp" ]] || fatal "Could not parse throughput from $LOG"
  printf '%s\n' "$tp" >> "$THR_FILE"
  log "Run $i/$ITERATIONS – throughput = $tp ops/sec"
done

stop_redis

log "Results"
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
echo   "Median ops/sec : $median"
echo   "Mean ops/sec   : $mean"
echo   "Std-Dev ops/sec: $stdev"
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
