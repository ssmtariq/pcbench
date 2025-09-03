#!/usr/bin/env bash
# 3_run_workload.sh — PCBench unified wrapper (uses existing SUT runners)
# - Creates perf_*_summary.json under ~/pcbench_runs/logs
# - Defaults CONFIG_FILE to pcbench/<sut>/configs/original.conf
# - Delegates actual benchmarking to per-SUT scripts

set -Eeuo pipefail

log(){ echo -e "[$(date +%T)] $*"; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

# ---------- CLI/env knobs (common) ----------
SUT="${SUT:-postgres}"                          # postgres | nginx | redis
WORKLOADS="${WORKLOADS:-all}"                   # accepted for CLI parity; per-SUT scripts may ignore
ITER="${ITER:-3}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
DURATION="${DURATION:-180}"
THREADCOUNT="${THREADCOUNT:-12}"
CONCURRENCY="${CONCURRENCY:-500}"               # nginx (mapped to CONNECTIONS)
CONFIG_FILE="${CONFIG_FILE:-}"                  # defaulted per SUT below

# ---------- paths & logs ----------
REPO_ROOT="${REPO_ROOT:-$HOME/pcbench}"
ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$LOG_DIR"

# ---------- perf wrapper (kept from original runner) ----------
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
  # Default CONFIG_FILE and script path
  local default_cfg="$REPO_ROOT/postgresql/configs/original.conf"
  CONFIG_FILE="${CONFIG_FILE:-$default_cfg}"
  ensure_file "$CONFIG_FILE"
  local runner="$REPO_ROOT/postgresql/pgsql_bench.sh"
  ensure_file "$runner"

  # Apply config, then run the existing PG runner (it manages warmup+measured runs internally)
  log "Postgres: applying config: $CONFIG_FILE"
  apply_pg_conf

  # pgsql_bench.sh currently sets its own ITERATIONS/time; our ITER/WARMUP/DURATION are not used by it
  # We still wrap it in perf to produce perf_*_summary.json like the original runner did.
  local label="pg_${TS}"
  log "Postgres: starting pgsql_bench.sh (perf label: $label)"
  perf_stat_wrap "$label" bash "$runner"
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

  # Optional: default wrk path if user built it per Nginx.md
  export WRK_BIN="${WRK_BIN:-$HOME/wrk/wrk}"   # Nginx.md instructions
  local label="nginx_${TS}"
  log "nginx: NGINX_CONF=$NGINX_CONF ITERATIONS=$ITER WARMUP_SECONDS=$WARMUP_SECONDS DURATION=$DURATION THREADS=$THREADS CONNECTIONS=$CONNECTIONS"
  perf_stat_wrap "$label" bash "$runner"
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
  # redis_bench.sh already maps DURATION→MEASURE_TIME, THREADS→THREADCOUNT internally

  local label="redis_${TS}"
  log "redis: REDIS_CONF=$REDIS_CONF ITERATIONS=$ITER WARMUP_SECONDS=$WARMUP_SECONDS DURATION=$DURATION THREADS=$THREADS"
  perf_stat_wrap "$label" bash "$runner"
}

# ---------- main ----------
case "$SUT" in
  postgres) run_postgres ;;
  nginx)    run_nginx    ;;
  redis)    run_redis    ;;
  *) die "Unknown SUT: $SUT" ;;
esac

log "All runs complete → summaries in $LOG_DIR"
