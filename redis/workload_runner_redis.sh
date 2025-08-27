#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Redis repeat-runner (memtier) with warmup + median ops/sec report
# -----------------------------------------------------------------------------
set -Eeuo pipefail
shopt -s inherit_errexit

log()   { printf '\n[%s] %s\n'  "$(date '+%F %T')"  "$*"; }
fatal() { printf '\n❌  %s\n'   "$*" >&2; exit 1; }
trap 'fatal "Command \"${BASH_COMMAND}\" failed (line ${LINENO})"' ERR

REDIS_SERVER=${REDIS_SERVER:-$(command -v redis-server || true)}
REDIS_CLI=${REDIS_CLI:-$(command -v redis-cli || true)}
MEMTIER=${MEMTIER:-$(command -v memtier_benchmark || true)}
REDIS_CONF=${REDIS_CONF:-$HOME/TUNA_best_redis_config.conf}
REDIS_PORT=${REDIS_PORT:-6379}
REDIS_HOST=${REDIS_HOST:-127.0.0.1}

# Benchmark shape (tweak as needed)
WARMUP_TIME=${WARMUP_TIME:-60}
MEASURE_TIME=${MEASURE_TIME:-180}
THREADS=${THREADS:-4}
CLIENTS_PER_THREAD=${CLIENTS_PER_THREAD:-25}
PIPELINE=${PIPELINE:-32}
RATIO=${RATIO:-1:1}
DATA_SIZE=${DATA_SIZE:-512}       # bytes
KEY_MAX=${KEY_MAX:-500000}

ITERATIONS=${ITERATIONS:-10}
TMPDIR="$(mktemp -d)"
THR_FILE="$TMPDIR/throughputs.txt"
RESULTS_FILE="${RESULTS_FILE:-$HOME/redis_bench_results.log}"

[[ -x "$REDIS_SERVER" ]] || fatal "redis-server not found; set REDIS_SERVER=/path/to/redis-server"
[[ -x "$MEMTIER" ]] || fatal "memtier_benchmark not found; install and/or set MEMTIER"

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

extract_ops() {
  # Parse Ops/sec from memtier output (Totals Ops/sec: <num>)
  grep -oP '(?i)Ops/sec:\s+\K[0-9.]+' "$1" | tail -n1
}

prefill() {
  log "Prefill dataset with SETs (~5% of keyspace)"
  "$MEMTIER" -s "$REDIS_HOST" -p "$REDIS_PORT" \
    --hide-histogram \
    --ratio=1:0 --data-size="$DATA_SIZE" \
    --key-minimum=1 --key-maximum="$KEY_MAX" \
    --pipeline="$PIPELINE" --threads="$THREADS" --clients="$CLIENTS_PER_THREAD" \
    --requests="$(( KEY_MAX / 20 ))" >/dev/null
}

log "Workspace : $TMPDIR"
start_redis
prefill

log "Starting $ITERATIONS timed runs"
for i in $(seq 1 "$ITERATIONS"); do
  # Flush between runs for repeatability
  if [[ -x "$REDIS_CLI" ]]; then "$REDIS_CLI" -h "$REDIS_HOST" -p "$REDIS_PORT" FLUSHALL >/dev/null; fi

  # Warmup
  WLOG="$TMPDIR/warmup_${i}.log"
  log "Run $i/$ITERATIONS – warmup ${WARMUP_TIME}s"
  "$MEMTIER" -s "$REDIS_HOST" -p "$REDIS_PORT" \
    --hide-histogram \
    --test-time="$WARMUP_TIME" \
    --ratio="$RATIO" --data-size="$DATA_SIZE" \
    --key-minimum=1 --key-maximum="$KEY_MAX" \
    --pipeline="$PIPELINE" --threads="$THREADS" --clients="$CLIENTS_PER_THREAD" \
    > "$WLOG" 2>&1 || true

  # Measured
  LOG="$TMPDIR/run_${i}.log"
  log "Run $i/$ITERATIONS – measure ${MEASURE_TIME}s"
  "$MEMTIER" -s "$REDIS_HOST" -p "$REDIS_PORT" \
    --hide-histogram \
    --test-time="$MEASURE_TIME" \
    --ratio="$RATIO" --data-size="$DATA_SIZE" \
    --key-minimum=1 --key-maximum="$KEY_MAX" \
    --pipeline="$PIPELINE" --threads="$THREADS" --clients="$CLIENTS_PER_THREAD" \
    > "$LOG" 2>&1

  tp=$(extract_ops "$LOG")
  [[ -n "$tp" ]] || fatal "Could not parse Ops/sec from $LOG"
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
