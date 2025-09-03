#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo -e "[$(date +%T)] $*"; }
warn(){ echo -e "[$(date +%T)] ⚠️  $*" >&2; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
HPCRUN_OUT="${HPCRUN_OUT:-$ARTI_ROOT/hpctoolkit_measurements}"
HPC_DB="${HPC_DB:-$ARTI_ROOT/hpctoolkit_database}"
SUT="${SUT:-postgres}"
DURATION="${DURATION:-180}"
THREADS="${THREADS:-$(nproc || echo 8)}"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

[ -f "$ARTI_ROOT/memory_confirmed.flag" ] || { warn "No memory_confirmed.flag; run anyway by setting FORCE_PROFILE=1"; [ "${FORCE_PROFILE:-0}" = "1" ] || exit 0; }

rm -rf "$HPCRUN_OUT" "$HPC_DB"

case "$SUT" in
  postgres)
    pg_ctl -D "$HOME/pgdata" stop || true
    log "hpcrun wrapping Postgres start"
    hpcrun -o "$HPCRUN_OUT" -e PAPI_L2_TCM@1000 -e PAPI_L3_TCM@1000 -- pg_ctl -D "$HOME/pgdata" -l "$LOG_DIR/pg_hpcrun.log" start
    sleep 2
    log "Driving medium run for ${DURATION}s"
    timeout "$DURATION" tail -f "$LOG_DIR/pg_hpcrun.log" >/dev/null 2>&1 || true
    pg_ctl -D "$HOME/pgdata" stop
    ;;
  nginx)
    log "hpcrun (client-side activity capture during ab)"
    hpcrun -o "$HPCRUN_OUT" -e PAPI_L2_TCM@1000 -e PAPI_L3_TCM@1000 -- bash -lc "ab -k -c 500 -t ${DURATION} http://127.0.0.1/" || true
    ;;
  redis)
    log "hpcrun wrapping redis-server during benchmark"
    pkill -x redis-server || true
    hpcrun -o "$HPCRUN_OUT" -e PAPI_L2_TCM@1000 -e PAPI_L3_TCM@1000 -- redis-server --save "" --appendonly no &
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
