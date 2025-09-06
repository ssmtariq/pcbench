#!/usr/bin/env bash
# 3_run_workload.sh — PCBench unified wrapper (uses existing SUT runners)
# - Creates perf_*_summary.json under ~/pcbench_runs/logs
# - Delegates actual benchmarking to per-SUT scripts

set -Eeuo pipefail

log(){ echo -e "[$(date +%T)] $*"; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

# ---------- CLI/env knobs (common) ----------
SUT="${SUT:-postgresql}"                 # postgresql | nginx | redis
WORKLOADS="${WORKLOADS:-small}"          # small | large | xl  (mapped to per-SUT)
ITER="${ITER:-3}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
DURATION="${DURATION:-180}"
THREADCOUNT="${THREADCOUNT:-12}"
CONCURRENCY="${CONCURRENCY:-500}"        # nginx (mapped to CONNECTIONS)
CONFIG_FILE="${CONFIG_FILE:-}"           # defaulted per SUT below
MEASURE_TARGET="${MEASURE_TARGET:-server}"   # server | client | system | server_exec
RAMP_SECONDS="${RAMP_SECONDS:-5}"        # time to let clients connect before attaching perf
PID_RETRY_SEC="${PID_RETRY_SEC:-15}"     # seconds to retry collecting server PIDs

# ---------- paths & logs ----------
REPO_ROOT="${REPO_ROOT:-$HOME/pcbench}"
ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$LOG_DIR"

# ---------- perf wrappers ----------
perf_stat_wrap(){
  local label="$1"; shift
  local raw="$LOG_DIR/perf_${label}_raw.txt"
  local sum="$LOG_DIR/perf_${label}_summary.json"

  perf stat -x, -e cycles,instructions,cache-references,cache-misses,branches,branch-misses,context-switches,major-faults \
    -- "$@" 1>/dev/null 2> "$raw" || true

  python3 - "$raw" "$sum" <<'PY'
import json,sys
raw,out=sys.argv[1],sys.argv[2]
m={}
for L in open(raw):
  p=L.strip().split(',')
  if len(p)<3: continue
  try: v=float(p[0])
  except: continue
  k=p[2].strip().replace('-','_').replace(':','_').replace(' ','_')
  m[k]=v
open(out,'w').write(json.dumps(m,indent=2))
print(out)
PY
}

perf_stat_attach_pids_during(){
  local label="$1"; shift
  local pids_csv="$1"; shift
  local raw="$LOG_DIR/perf_${label}_raw.txt"
  local sum="$LOG_DIR/perf_${label}_summary.json"

  ( perf stat -x, -p "$pids_csv" \
      -e cycles,instructions,cache-references,cache-misses,branches,branch-misses,context-switches,major-faults \
      -- sleep "${DURATION}" ) 1>/dev/null 2> "$raw" & PERF_PID=$!

  "$@" || true
  wait "$PERF_PID" || true

  python3 - "$raw" "$sum" <<'PY'
import json,sys
raw,out=sys.argv[1],sys.argv[2]
m={}
for L in open(raw):
  p=L.strip().split(',')
  if len(p)<3: continue
  try: v=float(p[0])
  except: continue
  k=p[2].strip().replace('-','_').replace(':','_').replace(' ','_')
  m[k]=v
open(out,'w').write(json.dumps(m,indent=2))
print(out)
PY
}

perf_stat_attach_pids_for(){
  local label="$1"; shift
  local pids_csv="$1"; shift
  local secs="$1"; shift
  local raw="$LOG_DIR/perf_${label}_raw.txt"
  local sum="$LOG_DIR/perf_${label}_summary.json"

  perf stat -x, -p "$pids_csv" \
    -e cycles,instructions,cache-references,cache-misses,branches,branch-misses,context-switches,major-faults \
    -- sleep "$secs" 1>/dev/null 2> "$raw" || true

  python3 - "$raw" "$sum" <<'PY'
import json,sys
raw,out=sys.argv[1],sys.argv[2]
m={}
for L in open(raw):
  p=L.strip().split(',')
  if len(p)<3: continue
  try: v=float(p[0])
  except: continue
  k=p[2].strip().replace('-','_').replace(':','_').replace(' ','_')
  m[k]=v
open(out,'w').write(json.dumps(m,indent=2))
print(out)
PY
}

# ---------- helpers ----------
ensure_file(){ [[ -f "$1" ]] || die "Required file not found: $1"; }

apply_pg_conf(){
  # Append/override settings from CONFIG_FILE into live postgresql.conf, then restart
  local pgdata="${PGDATA:-$HOME/pgdata}"
  ensure_file "$CONFIG_FILE"
  [[ -d "$pgdata" ]] || die "PGDATA not found: $pgdata"
  cp "$pgdata/postgresql.conf" "$pgdata/postgresql.conf.bak.$(date +%s)"
  cat "$CONFIG_FILE" >> "$pgdata/postgresql.conf"
  pg_ctl -D "$pgdata" restart -m fast
}

# Map WORKLOADS -> BenchBase XML
pg_resolve_xml_for_workload(){
  local size="$1"
  local base="$HOME/benchbase/target/benchbase-postgres/config/postgres"
  case "$size" in
    small) echo "$base/xl170_tpcc_small.xml" ;;
    large) echo "$base/xl170_tpcc_large.xml" ;;
    xl)    echo "$base/xl170_tpcc_xl.xml" ;;
    *)     echo "$base/xl170_tpcc_small.xml" ;;
  esac
}

# Extract <time> from BenchBase XML
pg_parse_time_from_xml(){
  local xml="$1"
  [[ -f "$xml" ]] || { echo ""; return; }
  awk 'tolower($0) ~ /<time>/ { gsub(/.*<time>|<\/time>.*/, "", $0); if ($0 ~ /^[0-9]+$/){print $0; exit} }' "$xml"
}

# collect postgres PIDs (retry window)
pg_collect_pids_retry(){
  local until=$(( $(date +%s) + PID_RETRY_SEC ))
  local p=""
  while :; do
    p="$(pgrep -x postgres | paste -sd, -)"
    [[ -n "$p" ]] && { echo "$p"; return; }
    [[ $(date +%s) -ge $until ]] && { echo ""; return; }
    sleep 0.5
  done
}

# ---------- per-SUT invocations ----------
run_postgres(){
  local default_cfg="$REPO_ROOT/postgresql/configs/original.conf"
  CONFIG_FILE="${CONFIG_FILE:-$default_cfg}"
  ensure_file "$CONFIG_FILE"
  local runner="$REPO_ROOT/postgresql/pgsql_bench.sh"
  ensure_file "$runner"

  # Map wrapper vars -> runner env (the runner already understands WORKLOAD)
  if [[ -n "${WORKLOADS:-}" ]]; then
    case "$WORKLOADS" in small|large|xl) export WORKLOAD="$WORKLOADS" ;; esac
  fi
  [[ -n "${ITER:-}" ]] && export ITERATIONS="$ITER"
  [[ -n "${WARMUP_SECONDS:-}" ]] && export WARMUP_SECONDS
  [[ -n "${DURATION:-}" ]] && export DURATION
  [[ -n "${THREADCOUNT:-}" ]] && export THREADCOUNT

  log "Postgres: applying config: $CONFIG_FILE"
  apply_pg_conf

  # Ensure server is up
  local pgdata="${PGDATA:-$HOME/pgdata}"
  pg_ctl -D "$pgdata" -l "$LOG_DIR/pg.log" status >/dev/null 2>&1 || \
    pg_ctl -D "$pgdata" -l "$LOG_DIR/pg.log" start

  local label="pg_${TS}"

  # --- server_exec: start runner, ramp, attach for execute window from XML ---
  if [ "$MEASURE_TARGET" = "server_exec" ]; then
    log "Postgres: server_exec → start client, ramp ${RAMP_SECONDS}s, attach to server PIDs for execute window"
    ( bash "$runner" ) & RUNNER_PID=$!

    # ramp so client connects and backends fork
    sleep "$RAMP_SECONDS"

    # gather PIDs with retries
    local pids; pids="$(pg_collect_pids_retry)"
    if [[ -z "$pids" ]]; then
      log "Postgres: could not resolve server PIDs; falling back to client wrap"
      wait "$RUNNER_PID" || true
      perf_stat_wrap "$label" true
      return
    fi

    # derive execute seconds from XML (fallback: DURATION)
    local xml secs
    xml="$(pg_resolve_xml_for_workload "${WORKLOAD:-${WORKLOADS:-small}}")"
    secs="$(pg_parse_time_from_xml "$xml")"
    [[ -z "$secs" ]] && secs="$DURATION"

    log "Postgres: attaching to PIDs: $pids for ${secs}s (execute window)"
    perf_stat_attach_pids_for "$label" "$pids" "$secs"

    wait "$RUNNER_PID" || true
    return
  fi
  # --- server (whole run) ---
  local pids_all; pids_all="$(pg_collect_pids_retry)"
  if [ "$MEASURE_TARGET" = "server" ] && [ -n "$pids_all" ]; then
    log "Postgres: attaching perf to server PIDs: $pids_all (duration=${DURATION}s); running pgsql_bench.sh"
    perf_stat_attach_pids_during "$label" "$pids_all" bash "$runner"
  else
    log "Postgres: MEASURE_TARGET=$MEASURE_TARGET or no PIDs → wrapping client runner"
    perf_stat_wrap "$label" bash "$runner"
  fi
}

run_nginx(){
  local default_cfg="$REPO_ROOT/nginx/configs/original.conf"
  CONFIG_FILE="${CONFIG_FILE:-$default_cfg}"
  ensure_file "$CONFIG_FILE"
  local runner="$REPO_ROOT/nginx/nginx_bench.sh"
  ensure_file "$runner"

  export NGINX_CONF="$CONFIG_FILE"
  export ITERATIONS="$ITER"
  export WARMUP_SECONDS="$WARMUP_SECONDS"
  export DURATION="$DURATION"
  export THREADS="${THREADCOUNT}"
  export CONNECTIONS="${CONCURRENCY}"
  export WRK_BIN="${WRK_BIN:-$HOME/wrk/wrk}"

  sudo systemctl is-active nginx >/dev/null 2>&1 || sudo systemctl start nginx || true
  sleep 1
  local master=""; [ -f /run/nginx.pid ] && master="$(cat /run/nginx.pid 2>/dev/null || true)"
  local workers="$(pgrep -f 'nginx: worker process' | tr '\n' ',' | sed 's/,$//')"
  local pids_csv="$master${workers:+,$workers}"

  local label="nginx_${TS}"
  if [ "$MEASURE_TARGET" = "server" ] && [ -n "$pids_csv" ]; then
    log "nginx: attaching perf to server PIDs: $pids_csv (duration=${DURATION}s); running nginx_bench.sh"
    perf_stat_attach_pids_during "$label" "$pids_csv" bash "$runner"
  else
    log "nginx: MEASURE_TARGET=$MEASURE_TARGET or no PIDs → wrapping client runner"
    perf_stat_wrap "$label" bash "$runner"
  fi
}

run_redis(){
  local default_cfg="$REPO_ROOT/redis/configs/original.conf"
  CONFIG_FILE="${CONFIG_FILE:-$default_cfg}"
  ensure_file "$CONFIG_FILE"
  local runner="$REPO_ROOT/redis/redis_bench.sh"
  ensure_file "$runner"

  export REDIS_CONF="$CONFIG_FILE"
  export ITERATIONS="$ITER"
  export WARMUP_SECONDS="$WARMUP_SECONDS"
  export DURATION="$DURATION"
  export THREADS="${THREADCOUNT}"

  pgrep -x redis-server >/dev/null 2>&1 || (nohup redis-server --save "" --appendonly no >/dev/null 2>&1 & sleep 1)
  local pids_csv="$(pgrep -x redis-server | tr '\n' ',' | sed 's/,$//')"

  local label="redis_${TS}"
  if [ "$MEASURE_TARGET" = "server" ] && [ -n "$pids_csv" ]; then
    log "redis: attaching perf to server PIDs: $pids_csv (duration=${DURATION}s); running redis_bench.sh"
    perf_stat_attach_pids_during "$label" "$pids_csv" bash "$runner"
  else
    log "redis: MEASURE_TARGET=$MEASURE_TARGET or no PIDs → wrapping client runner"
    perf_stat_wrap "$label" bash "$runner"
  fi
}

# ---------- main ----------
case "$SUT" in
  postgresql) run_postgres ;;
  nginx)      run_nginx    ;;
  redis)      run_redis    ;;
  *) die "Unknown SUT: $SUT" ;;
esac

log "All runs complete → summaries in $LOG_DIR"
