#!/usr/bin/env bash
# 3_run_workload.sh — PCBench unified wrapper (uses existing SUT runners)
# - Creates perf_*_summary.json under ~/pcbench_runs/logs
# - Defaults CONFIG_FILE to pcbench/<sut>/configs/original.conf
# - Delegates actual benchmarking to per-SUT scripts

set -Eeuo pipefail

log(){ echo -e "[$(date +%T)] $*"; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

# ---------- CLI/env knobs (common) ----------
SUT="${SUT:-postgresql}"                        # postgresql | nginx | redis
WORKLOADS="${WORKLOADS:-all}"                   # accepted for CLI parity; per-SUT scripts may ignore
ITER="${ITER:-3}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
DURATION="${DURATION:-180}"
THREADCOUNT="${THREADCOUNT:-12}"
CONCURRENCY="${CONCURRENCY:-500}"               # nginx (mapped to CONNECTIONS)
CONFIG_FILE="${CONFIG_FILE:-}"                  # defaulted per SUT below
MEASURE_TARGET="${MEASURE_TARGET:-server}"      # server | client | system

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

# NEW: attach perf to server PIDs for a fixed window while running the client
perf_stat_attach_pids_during(){
  local label="$1"; shift
  local pids_csv="$1"; shift
  local raw="$LOG_DIR/perf_${label}_raw.txt"
  local sum="$LOG_DIR/perf_${label}_summary.json"

  # Start perf attached to PIDs for DURATION seconds, then run the client concurrently
  ( perf stat -x, -p "$pids_csv" \
      -e cycles,instructions,cache-references,cache-misses,branches,branch-misses,context-switches,major-faults \
      -- sleep "${DURATION}" ) 1>/dev/null 2> "$raw" & PERF_PID=$!

  # Run client workload (benchmark runner) while perf is active
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

# ---------- per-SUT invocations ----------
run_postgres(){
  # Defaults
  local default_cfg="$REPO_ROOT/postgresql/configs/original.conf"
  CONFIG_FILE="${CONFIG_FILE:-$default_cfg}"
  ensure_file "$CONFIG_FILE"
  local runner="$REPO_ROOT/postgresql/pgsql_bench.sh"
  ensure_file "$runner"

  log "Postgres: applying config: $CONFIG_FILE"
  apply_pg_conf

  # Ensure server is up (so we can attach to its PIDs)
  pg_ctl -D "${PGDATA:-$HOME/pgdata}" -l "$LOG_DIR/pg.log" status >/dev/null 2>&1 || \
    pg_ctl -D "${PGDATA:-$HOME/pgdata}" -l "$LOG_DIR/pg.log" start

  local pids
  pids="$(pgrep -x postgres | tr '\n' ',' | sed 's/,$//')"

  # NEW: map wrapper knobs -> pgsql_bench.sh env
  export ITERATIONS="${ITER:-1}"
  if [[ -z "${WARMUP:-}" ]]; then
    # Enable warmup only if user asked via seconds > 0
    if (( ${WARMUP_SECONDS:-0} > 0 )); then export WARMUP=1; else export WARMUP=0; fi
  fi
  # Optional: let user override workload size specifically for Postgres
  if [[ -n "${POSTGRES_WORKLOAD:-}" ]]; then export WORKLOAD="$POSTGRES_WORKLOAD"; fi
  # Optional: pass through sample interval if provided
  [[ -n "${SAMPLE_INTERVAL:-}" ]] && export SAMPLE_INTERVAL

  local label="pg_${TS}"
  if [ "$MEASURE_TARGET" = "server" ] && [ -n "$pids" ]; then
    log "Postgres: attaching perf to server PIDs: $pids (duration=${DURATION}s); running pgsql_bench.sh"
    perf_stat_attach_pids_during "$label" "$pids" bash "$runner"
  else
    log "Postgres: MEASURE_TARGET=$MEASURE_TARGET or no PIDs → wrapping client runner"
    perf_stat_wrap "$label" bash "$runner"
  fi
}

run_nginx(){
  # Defaults + paths
  local default_cfg="$REPO_ROOT/nginx/configs/original.conf"
  CONFIG_FILE="${CONFIG_FILE:-$default_cfg}"
  ensure_file "$CONFIG_FILE"
  local runner="$REPO_ROOT/nginx/nginx_bench.sh"
  ensure_file "$runner"

  # Map wrapper vars -> nginx_bench.sh env
  export NGINX_CONF="$CONFIG_FILE"
  export ITERATIONS="$ITER"
  export WARMUP_SECONDS="$WARMUP_SECONDS"
  export DURATION="$DURATION"
  export THREADS="${THREADCOUNT}"
  export CONNECTIONS="${CONCURRENCY}"
  export WRK_BIN="${WRK_BIN:-$HOME/wrk/wrk}"

  # Ensure nginx is up so we can attach to it (bench script may also manage it)
  sudo systemctl is-active nginx >/dev/null 2>&1 || sudo systemctl start nginx || true
  sleep 1
  # Collect master + worker PIDs
  local master=""
  [ -f /run/nginx.pid ] && master="$(cat /run/nginx.pid 2>/dev/null || true)"
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
  # Defaults + paths
  local default_cfg="$REPO_ROOT/redis/configs/original.conf"
  CONFIG_FILE="${CONFIG_FILE:-$default_cfg}"
  ensure_file "$CONFIG_FILE"
  local runner="$REPO_ROOT/redis/redis_bench.sh"
  ensure_file "$runner"

  # Map wrapper vars -> redis_bench.sh env
  export REDIS_CONF="$CONFIG_FILE"
  export ITERATIONS="$ITER"
  export WARMUP_SECONDS="$WARMUP_SECONDS"
  export DURATION="$DURATION"
  export THREADS="${THREADCOUNT}"

  # Ensure redis-server is up so we can attach PIDs (bench script may also manage it)
  pgrep -x redis-server >/dev/null 2>&1 || (nohup redis-server --save "" --appendonly no >/dev/null 2>&1 & sleep 1)
  local pids_csv
  pids_csv="$(pgrep -x redis-server | tr '\n' ',' | sed 's/,$//')"

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
  nginx)    run_nginx    ;;
  redis)    run_redis    ;;
  *) die "Unknown SUT: $SUT" ;;
esac

log "All runs complete → summaries in $LOG_DIR"
