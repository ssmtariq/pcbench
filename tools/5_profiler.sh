#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo -e "[$(date +%T)] $*"; }
warn(){ echo -e "[$(date +%T)] ⚠️  $*" >&2; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
HPCRUN_OUT="${HPCRUN_OUT:-$ARTI_ROOT/hpctoolkit_measurements}"
HPC_DB="${HPC_DB:-$ARTI_ROOT/hpctoolkit_database}"
SUT="${SUT:-postgresql}"
DURATION="${DURATION:-180}"
THREADS="${THREADS:-$(nproc || echo 8)}"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

[ -f "$ARTI_ROOT/memory_confirmed.flag" ] || { warn "No memory_confirmed.flag; run anyway by setting FORCE_PROFILE=1"; [ "${FORCE_PROFILE:-0}" = "1" ] || exit 0; }

rm -rf "$HPCRUN_OUT" "$HPC_DB"

case "$SUT" in
  postgresql)
    pg_ctl -D "$HOME/pgdata" stop || true
    log "hpcrun wrapping Postgres start"
    hpcrun -o "$HPCRUN_OUT" \
           -e PAPI_L2_TCM@1000 \
           -e PAPI_L3_TCM@1000 \
           -- pg_ctl -D "$HOME/pgdata" -l "$LOG_DIR/pg_hpcrun.log" start
    sleep 2
    log "Driving medium run for ${DURATION}s"
    timeout "$DURATION" tail -f "$LOG_DIR/pg_hpcrun.log" >/dev/null 2>&1 || true
    pg_ctl -D "$HOME/pgdata" stop
    ;;
  nginx)
    # FIX: profile nginx itself (not the client), following your requested command style
    NGINX_BIN="${NGINX_BIN:-$(command -v nginx)}"
    NGINX_CONF="${NGINX_CONF:-$HOME/pcbench/nginx/configs/original.conf}"
    [ -x "$NGINX_BIN" ] || die "nginx not found"
    [ -f "$NGINX_CONF" ] || die "nginx conf not found: $NGINX_CONF"
    log "Stopping any running nginx to avoid conflicts"
    sudo "$NGINX_BIN" -s stop >/dev/null 2>&1 || sudo systemctl stop nginx >/dev/null 2>&1 || true

    log "hpcrun wrapping nginx: $NGINX_BIN -c $NGINX_CONF -p $(dirname "$(dirname "$NGINX_CONF")")"
    hpcrun  -o "$HPCRUN_OUT" \
            -e PAPI_L2_TCM@1000 \
            -e PAPI_L3_TCM@1000 \
            -- "$NGINX_BIN" -c "$NGINX_CONF" -p "$(dirname "$(dirname "$NGINX_CONF")")" &
    NGINX_HPCRUN_PID=$!
    sleep 2

    # Drive load with ab during profiling window
    log "Driving ab load for ${DURATION}s"
    timeout "$DURATION" ab -k -c 500 -t "$DURATION" http://127.0.0.1/ || true

    # Stop nginx started above
    "$NGINX_BIN" -s stop >/dev/null 2>&1 || sudo systemctl stop nginx >/dev/null 2>&1 || true
    wait "$NGINX_HPCRUN_PID" 2>/dev/null || true
    ;;
  redis)
    log "hpcrun wrapping redis-server during benchmark"
    pkill -x redis-server || true
    hpcrun -o "$HPCRUN_OUT" \
           -e PAPI_L2_TCM@1000 \
           -e PAPI_L3_TCM@1000 \
           -- redis-server "$HOME/pcbench/redis/configs/TUNA_best_redis_config.conf" --port 6379 --protected-mode no &
    sleep 2
    timeout "$DURATION" redis-benchmark -t get,set -n 100000000 -P 16 -c 300 -d 128 -q || true
    pkill -x redis-server || true
    ;;
  *) die "Unknown SUT: $SUT";;
esac

log "Building hpcstruct/hpcprof…"
hpcstruct -j "$THREADS" "$HPCRUN_OUT" || true
hpcprof   -j "$THREADS" -o "$HPC_DB" "$HPCRUN_OUT"

[ -d "$HPC_DB" ] || die "HPCToolkit database not created."
log "HPCToolkit DB ready → $HPC_DB"
