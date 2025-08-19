#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# nginx_bench.sh – repeat-runner for nginx performance evaluation
#
# This script evaluates an nginx installation using the ``wrk`` HTTP
# benchmarking tool.  It borrows design ideas from the PC Bench `wrv2.sh`
# script: each run fast‑restarts the server, drives a fixed‑length
# workload, extracts the throughput, and finally computes summary
# statistics (mean, median, standard deviation) across all runs.  A
# temporary directory holds logs and intermediate files.
#
# Usage:
#   ./nginx_bench.sh
#
# Before running you must set the following environment variables or edit
# the corresponding variables below:
#   NGINX_BIN      – full path to the nginx binary (e.g., ~/nginx/sbin/nginx)
#   NGINX_CONF     – nginx configuration file to test
#   WRK_BIN        – full path to the wrk binary
#   URL            – target URL served by nginx (default http://localhost/)
# You may also adjust ITERATIONS, DURATION, THREADS and CONNECTIONS.

set -Eeuo pipefail
shopt -s inherit_errexit        # traps ERR even in subshells

# -------- logging helpers ----------------------------------------------------
log()   { printf '\n[%s] %s\n'  "$(date '+%F %T')"  "$*"; }
fatal() { printf '\n❌  %s\n'   "$*" >&2; exit 1; }
trap 'fatal "Command \"${BASH_COMMAND}\" failed (line ${LINENO})"' ERR

# -------- user‑configurable variables ---------------------------------------
NGINX_BIN=${NGINX_BIN:-"$HOME/nginx/sbin/nginx"}
NGINX_CONF=${NGINX_CONF:-"$HOME/nginx/conf/nginx.conf"}
WRK_BIN=${WRK_BIN:-"$HOME/wrk/wrk"}

# Default URL to benchmark; adjust if your server listens elsewhere.
URL=${URL:-"http://localhost:8080/"}

# Number of iterations to run.  Each iteration restarts nginx and
# performs one measurement run.  More iterations yield smoother
# statistics but take longer.
ITERATIONS=${ITERATIONS:-1}

# Duration of each wrk run (in seconds).  Increase for more stable
# measurements.
DURATION=${DURATION:-30}

# Number of wrk threads and open connections.  Choose values that
# saturate your server without causing resource exhaustion.
THREADS=${THREADS:-10}
CONNECTIONS=${CONNECTIONS:-10}
WARMUP_SECONDS=${WARMUP_SECONDS:-0}

# -------- derived constants --------------------------------------------------
TMPDIR=$(mktemp -d)
THR_FILE="$TMPDIR/throughputs.txt"
RESULTS_FILE="${RESULTS_FILE:-$HOME/nginx_bench_results.log}"   # final report

log "Workspace      : $TMPDIR"
log "nginx binary    : $NGINX_BIN"
log "Config file    : $NGINX_CONF"
log "wrk binary     : $WRK_BIN"
log "Target URL     : $URL"
log "Iterations     : $ITERATIONS (duration ${DURATION}s, threads ${THREADS}, connections ${CONNECTIONS})"

# Ensure required binaries exist
[[ -x "$NGINX_BIN" ]] || fatal "nginx binary not executable: $NGINX_BIN"
[[ -f "$NGINX_CONF" ]]    || fatal "configuration file not found: $NGINX_CONF"
[[ -x "$WRK_BIN" ]]   || fatal "wrk binary not executable: $WRK_BIN"

# Function to stop nginx quietly
stop_nginx() {
  if pgrep -x nginx >/dev/null 2>&1; then
    "$NGINX_BIN" -c "$NGINX_CONF" -p "$NGINX_PREFIX" -s stop >/dev/null 2>&1 || true
    # Wait for processes to exit
    sleep 2
  fi
}

# -------- 1. benchmark loop --------------------------------------------------
log "Starting $ITERATIONS timed runs"
for i in $(seq 1 "$ITERATIONS"); do
  log "Run $i/$ITERATIONS – starting nginx"
  # Stop any existing nginx instance (if leftover from previous run)
  stop_nginx
  # Start nginx with the given config.  The -c option specifies the
  # configuration file; -p sets the prefix (root) directory so that
  # relative paths inside the config resolve correctly.  Here we use
  # the parent directory of the config as prefix.
  # NGINX_PREFIX=$(dirname "$NGINX_CONF")
  NGINX_PREFIX=$(dirname "$(dirname "$NGINX_CONF")")
  "$NGINX_BIN" -c "$NGINX_CONF" -p "$NGINX_PREFIX"
  # Give nginx a moment to bind sockets
  sleep 2

  # Drive the workload using wrk.  The --latency flag reports detailed
  # latency distribution which may help later analysis.  Write output to
  # a per‑iteration log for later inspection.
  LOG="$TMPDIR/run_${i}.log"
  log "Run $i/$ITERATIONS – executing wrk for ${DURATION}s"
  "$WRK_BIN" -t "$THREADS" -c "$CONNECTIONS" -d "${DURATION}s" --latency "$URL" \
    | tee "$LOG"

  # Extract throughput (requests per second).  wrk prints a line like
  # "Requests/sec:  123456.78"; we use awk to pick the numeric value.
  tp=$(awk '/Requests\/sec:/ {print $2}' "$LOG" | tr -d '\r')
  if [[ -z "$tp" ]]; then
    fatal "Throughput not found in $LOG"
  fi
  printf '%s\n' "$tp" >> "$THR_FILE"
  log "Run $i/$ITERATIONS – throughput = $tp req/sec"

  # Stop nginx before the next iteration
  stop_nginx
done

# -------- 2. report ----------------------------------------------------------
log "Completed runs.  Computing summary statistics."

# Print per‑run throughputs with numbering
echo -e "\n────────── Throughput per run (req/sec) ──────────"
nl -ba "$THR_FILE"

# Sort the throughput numbers for median calculation
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

echo -e "────────────────────────────────────────────"
echo   "Median Throughput : $median req/sec"
echo   "Mean Throughput   : $mean req/sec"
echo   "Std‑Dev Throughput: $stdev req/sec"
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