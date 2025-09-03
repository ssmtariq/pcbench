#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo -e "[$(date +%T)] $*"; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

SUT="${SUT:-postgres}"
WORKLOADS="${WORKLOADS:-small}"
ITER="${ITER:-3}"
CONF_PATH="${CONF_PATH:-}"
BENCH_CFG="${BENCH_CFG:-}"   # for PG
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
DURATION="${DURATION:-180}"
THREADCOUNT="${THREADCOUNT:-12}"
CONCURRENCY="${CONCURRENCY:-500}"

ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

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

ensure_pg_and_benchbase(){
  if command -v psql >/dev/null 2>&1; then :; else die "psql not found"; fi
  if [ ! -d "$HOME/benchbase/target/benchbase-postgres" ]; then
    log "Cloning & building BenchBase (postgres)"
    git clone --depth 1 https://github.com/cmu-db/benchbase.git "$HOME/benchbase"
    (cd "$HOME/benchbase" && ./mvnw clean package -P postgres -DskipTests)
    (mkdir -p "$HOME/benchbase/target" && cd "$HOME/benchbase/target" && tar xvzf benchbase-postgres.tgz)
  fi
  if ! psql -Atqc "select 1" >/dev/null 2>&1; then
    if [ ! -d "$HOME/pg16/bin" ]; then
      log "Building PostgreSQL 16.1 (debug symbols)"
      wget -q https://ftp.postgresql.org/pub/source/v16.1/postgresql-16.1.tar.gz -O /tmp/pg.tar.gz
      tar xf /tmp/pg.tar.gz -C "$HOME"
      (cd "$HOME/postgresql-16.1" && ./configure --prefix=$HOME/pg16 --enable-debug CFLAGS="-g -O2 -fno-omit-frame-pointer" && make -j"$(nproc)" && make install)
      echo 'export PATH=$HOME/pg16/bin:$PATH' >> "$HOME/.bashrc"
      export PATH="$HOME/pg16/bin:$PATH"
      initdb -D "$HOME/pgdata"
    fi
    pg_ctl -D "$HOME/pgdata" -l "$LOG_DIR/pg.log" start
  fi
  psql -c "select version();" >/dev/null
}

apply_pg_conf(){
  if [ -n "$CONF_PATH" ] && [ -f "$CONF_PATH" ]; then
    log "Applying PG config: $CONF_PATH"
    cp "$HOME/pgdata/postgresql.conf" "$HOME/pgdata/postgresql.conf.bak.$(date +%s)"
    cat "$CONF_PATH" >> "$HOME/pgdata/postgresql.conf"
    pg_ctl -D "$HOME/pgdata" restart
  fi
}

run_pg(){
  ensure_pg_and_benchbase
  apply_pg_conf
  local base="$HOME/benchbase/target/benchbase-postgres/config/postgres"
  local cfg_small="$base/xl170_tpcc_small.xml"
  local cfg_medium="$base/xl170_tpcc_medium.xml"
  local cfg_large="$base/xl170_tpcc_large.xml"
  # If user supplied a workload file (BENCH_CFG), use it; else generate simple ones if missing
  if [ -n "$BENCH_CFG" ] && [ -f "$BENCH_CFG" ]; then
    sizes=("$BENCH_CFG")
  else
    mkdir -p "$base"
    for s in small medium large; do
      f="$base/xl170_tpcc_${s}.xml"; [ -f "$f" ] && continue
      cp "$base/sample_tpcc_config.xml" "$f" || true
      xmlstarlet ed -L \
        -u '//parameters/url' -v "jdbc:postgresql://localhost:5432/benchbase?sslmode=disable" \
        -u '//parameters/username' -v "$USER" \
        -u '//parameters/password' -v "" \
        -u '//parameters/terminals' -v "${THREADCOUNT}" \
        -u '//parameters/works/work/time' -v "${DURATION}" "$f" || true
    done
    case "$WORKLOADS" in
      small) sizes=("$cfg_small");;
      medium) sizes=("$cfg_medium");;
      large) sizes=("$cfg_large");;
      all) sizes=("$cfg_small" "$cfg_medium" "$cfg_large");;
    esac
  fi
  psql -c "DROP DATABASE IF EXISTS benchbase;" || true
  psql -c "CREATE DATABASE benchbase;"

  for cfg in "${sizes[@]}"; do
    name="$(basename "$cfg" .xml)"
    log "PG: prepare (create/load) for $name"
    java -jar "$HOME/benchbase/target/benchbase-postgres/benchbase.jar" -b tpcc -c "$cfg" --create=true --load=true --execute=false || true
    for i in $(seq 1 "$ITER"); do
      label="pg_${name}_i${i}"
      log "PG: run $label (warmup=${WARMUP_SECONDS}s, duration=${DURATION}s)"
      if [ "$WARMUP_SECONDS" -gt 0 ]; then
        java -jar "$HOME/benchbase/target/benchbase-postgres/benchbase.jar" -b tpcc -c "$cfg" --create=false --load=false --execute=true >/dev/null 2>&1 || true
      fi
      perf_stat_wrap "$label" java -jar "$HOME/benchbase/target/benchbase-postgres/benchbase.jar" -b tpcc -c "$cfg" --create=false --load=false --execute=true
    done
  done
}

run_nginx(){
  if ! pgrep -x nginx >/dev/null 2>&1; then
    sudo apt-get update -y >/dev/null; sudo apt-get install -y nginx >/dev/null
    [ -n "$CONF_PATH" ] && [ -f "$CONF_PATH" ] && sudo cp "$CONF_PATH" /etc/nginx/nginx.conf
    sudo nginx -t
    sudo systemctl enable --now nginx
  fi
  declare -A conc
  case "$WORKLOADS" in
    small) conc=( [small]=$CONCURRENCY );;
    medium) conc=( [medium]=$CONCURRENCY );;
    large) conc=( [large]=$CONCURRENCY );;
    all) conc=( [small]=200 [medium]=500 [large]=1000 );;
  esac
  for level in "${!conc[@]}"; do
    for i in $(seq 1 "$ITER"); do
      label="nginx_${level}_i${i}"
      log "nginx: ab -k -c ${conc[$level]} -t ${DURATION} http://127.0.0.1/"
      perf_stat_wrap "$label" ab -k -c "${conc[$level]}" -t "${DURATION}" http://127.0.0.1/
    done
  done
}

run_redis(){
  pgrep -x redis-server >/dev/null 2>&1 || (nohup redis-server --save "" --appendonly no >/dev/null 2>&1 & sleep 1)
  declare -A clients
  case "$WORKLOADS" in
    small) clients=( [small]=100 );;
    medium) clients=( [medium]=300 );;
    large) clients=( [large]=800 );;
    all) clients=( [small]=100 [medium]=300 [large]=800 );;
  esac
  for level in "${!clients[@]}"; do
    for i in $(seq 1 "$ITER"); do
      label="redis_${level}_i${i}"
      log "redis-benchmark -c ${clients[$level]} -q -t get,set -d 128 (-t/params simplified) for ${DURATION}s"
      perf_stat_wrap "$label" bash -lc "timeout ${DURATION} redis-benchmark -t get,set -n 100000000 -P 16 -c ${clients[$level]} -d 128 -q"
    done
  done
}

case "$SUT" in
  postgres) run_pg;;
  nginx)    run_nginx;;
  redis)    run_redis;;
  *) die "Unknown SUT: $SUT";;
esac

log "All runs complete → summaries in $LOG_DIR"
