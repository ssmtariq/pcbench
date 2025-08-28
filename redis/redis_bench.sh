#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Redis repeat-runner (YCSB) with warm-up + median throughput report
#
# Usage pattern mirrors nginx_bench.sh via environment variables:
#   REDIS_CONF=... WARMUP_SECONDS=... ITERATIONS=... DURATION=... THREADS=... \
#   bash redis_bench.sh
#
# Optional YCSB/Redis knobs:
#   RECORDCOUNT (default 1800000)
#   OPERATIONCOUNT (default 2000000000)
#   WORKLOAD (default workloada)
#   YCSB_DIR (default $HOME/YCSB)
#   SKIP_LOAD=1   # set to skip the load phase (if you preloaded once)
#
# The script starts redis-server with REDIS_CONF, (optionally) loads the
# dataset with YCSB, runs an optional warm-up, then iterates N timed runs,
# parsing YCSB’s “[OVERALL], Throughput(ops/sec)” and reporting median/mean/std.
# -----------------------------------------------------------------------------
set -Eeuo pipefail
shopt -s inherit_errexit

log()   { printf '\n[%s] %s\n'  "$(date '+%F %T')"  "$*"; }
fatal() { printf '\n❌  %s\n'   "$*" >&2; exit 1; }
trap 'fatal "Command \"${BASH_COMMAND}\" failed (line ${LINENO})"' ERR

REDIS_SERVER=${REDIS_SERVER:-$(command -v redis-server || true)}
REDIS_CLI=${REDIS_CLI:-$(command -v redis-cli || true)}

# YCSB location
YCSB_DIR=${YCSB_DIR:-$HOME/YCSB}
YCSB_BIN=${YCSB_BIN:-$YCSB_DIR/bin/ycsb.sh}

# Config & server endpoint
REDIS_CONF=${REDIS_CONF:-$HOME/pcbench/redis/configs/TUNA_best_redis_config.conf}
REDIS_PORT=${REDIS_PORT:-6379}
REDIS_HOST=${REDIS_HOST:-127.0.0.1}

# Core workload shape (defaults mirror your current README/script)
WORKLOAD=${WORKLOAD:-workloada}
RECORDCOUNT=${RECORDCOUNT:-1800000}
OPERATIONCOUNT=${OPERATIONCOUNT:-2000000000}

# “nginx-style” knobs, with compatibility mapping
WARMUP_TIME=${WARMUP_TIME:-30}
MEASURE_TIME=${MEASURE_TIME:-300}
THREADCOUNT=${THREADCOUNT:-40}
ITERATIONS=${ITERATIONS:-3}

# Allow nginx-style env names:
if [[ -n "${WARMUP_SECONDS:-}" ]]; then WARMUP_TIME="$WARMUP_SECONDS"; fi
if [[ -n "${DURATION:-}" ]]; then MEASURE_TIME="$DURATION"; fi
if [[ -n "${THREADS:-}" ]]; then THREADCOUNT="$THREADS"; fi

# Optional: skip load if already pre-loaded (set SKIP_LOAD=1)
SKIP_LOAD=${SKIP_LOAD:-0}

TMPDIR="$(mktemp -d)"
THR_FILE="$TMPDIR/throughputs.txt"
# Only append if user provides RESULTS_FILE; otherwise, just print to console
RESULTS_FILE="${RESULTS_FILE:-}"

[[ -x "$REDIS_SERVER" ]] || fatal "redis-server not found; set REDIS_SERVER=/path/to/redis-server"
[[ -x "$YCSB_BIN" ]]     || fatal "YCSB launcher not found; set YCSB_DIR to your YCSB installation"
[[ -f "$REDIS_CONF" ]]   || fatal "Redis config not found: $REDIS_CONF"

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

# Extract throughput (ops/sec) from YCSB run output: “[OVERALL], Throughput(ops/sec), 12345.678”
extract_ops() {
  grep -i 'Throughput(ops/sec)' "$1" | tail -n1 | awk -F, '{gsub(/ /,"",$3); print $3}'
}

log "Workspace : $TMPDIR"
log "Config    : $REDIS_CONF"
log "Threads   : $THREADCOUNT"
log "Warmup    : ${WARMUP_TIME}s"
log "Duration  : ${MEASURE_TIME}s"
log "Iters     : $ITERATIONS"
log "Recordcount: $RECORDCOUNT  Operationcount: $OPERATIONCOUNT"
start_redis

# Optional dataset load
if [[ "$SKIP_LOAD" -ne 1 ]]; then
  log "Loading dataset (recordcount=$RECORDCOUNT) via YCSB"
  "$YCSB_BIN" load redis \
    -s -P "$YCSB_DIR/workloads/$WORKLOAD" \
    -p recordcount="$RECORDCOUNT" \
    -p operationcount="$OPERATIONCOUNT" \
    -p threadcount="$THREADCOUNT" \
    -p redis.host="$REDIS_HOST" \
    -p redis.port="$REDIS_PORT" \
    > "$TMPDIR/load.log" 2>&1
else
  log "SKIP_LOAD=1 – skipping YCSB load phase"
fi

# Optional warm-up
if (( WARMUP_TIME > 0 )); then
  log "Warm-up for ${WARMUP_TIME}s"
  "$YCSB_BIN" run redis \
    -s -P "$YCSB_DIR/workloads/$WORKLOAD" \
    -p recordcount="$RECORDCOUNT" \
    -p operationcount="$OPERATIONCOUNT" \
    -p threadcount="$THREADCOUNT" \
    -p maxexecutiontime="$WARMUP_TIME" \
    -p redis.host="$REDIS_HOST" \
    -p redis.port="$REDIS_PORT" \
    > "$TMPDIR/warmup.log" 2>&1 || true
fi

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

# Handle ITERATIONS=0 / no measurements case gracefully
if [[ ! -s "$THR_FILE" ]]; then
  log "No measured iterations; skipping stats."
  exit 0
fi

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

# Append only if RESULTS_FILE is provided by the user
if [[ -n "$RESULTS_FILE" ]]; then
  {
    echo '---'
    echo "$timestamp"
    echo "Runs  : $run_list"
    echo "Mean  : $mean"
    echo "Median: $median"
    echo "StdDev: $stdev"
  } >> "$RESULTS_FILE"
  log "Appended summary to $RESULTS_FILE"
fi
