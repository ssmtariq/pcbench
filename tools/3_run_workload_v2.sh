#!/usr/bin/env bash
# 3_run_workload.sh — robust server-side perf wrapper with cgroup attach + intervals
set -Eeuo pipefail

log(){ echo -e "[$(date +%F %T)] $*"; }
die(){ echo -e "[$(date +%F %T)] ❌ $*" >&2; exit 1; }

# ---------- CLI/env knobs ----------
SUT="${SUT:-postgresql}"                     # postgresql|nginx|redis
WORKLOADS="${WORKLOADS:-xl}"                 # small|large|xl
ITER="${ITER:-1}"
WARMUP_SECONDS="${WARMUP_SECONDS:-0}"
DURATION="${DURATION:-180}"
THREADCOUNT="${THREADCOUNT:-10}"
CONFIG_FILE="${CONFIG_FILE:-}"
MEASURE_TARGET="${MEASURE_TARGET:-server_exec}"   # server|client|system|server_exec
RAMP_SECONDS="${RAMP_SECONDS:-20}"               # give backends time to appear
PID_RETRY_SEC="${PID_RETRY_SEC:-30}"
INTERVAL_MS="${INTERVAL_MS:-1000}"               # perf stat interval print (ms)
ATTACH_MODE="${ATTACH_MODE:-auto}"               # auto|cgroup|pids
CGROUP_NAME="${CGROUP_NAME:-pcbench_pg}"         # cgroup (v2) name for Postgres
PERF_EVENTS="${PERF_EVENTS:-\
cycles,instructions,cache-references,cache-misses,branches,branch-misses,context-switches,major-faults,\
LLC-loads,LLC-load-misses,dTLB-load-misses,topdown-retiring,topdown-bad-spec,topdown-fe-bound,topdown-be-bound}"

# ---------- paths ----------
REPO_ROOT="${REPO_ROOT:-$HOME/pcbench}"
ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$LOG_DIR"

# ---------- helpers ----------
ensure_file(){ [[ -f "$1" ]] || die "Required file not found: $1"; }

pg_resolve_xml_for_workload(){
  local size="${1:-xl}"
  local base="$HOME/benchbase/target/benchbase-postgres/config/postgres"
  case "$size" in
    small) echo "$base/xl170_tpcc_small.xml" ;;
    large) echo "$base/xl170_tpcc_large.xml" ;;
    xl|*)  echo "$base/xl170_tpcc_xl.xml" ;;
  esac
}

pg_parse_time_from_xml(){
  local xml="$1"
  [[ -f "$xml" ]] || { echo ""; return; }
  awk 'tolower($0) ~ /<time>/ { gsub(/.*<time>|<\/time>.*/, "", $0); if ($0 ~ /^[0-9]+$/){print $0; exit} }' "$xml"
}

pg_collect_pids_once(){ pgrep -x postgres | paste -sd, - || true; }

have_cgroup_v2(){ mount | grep -q " type cgroup2 "; }

cg_path(){ echo "/sys/fs/cgroup/${CGROUP_NAME}"; }

cg_make(){
  local p; p="$(cg_path)"
  sudo mkdir -p "$p" 2>/dev/null || true
  [[ -d "$p" ]] || return 1
  # Enable subtree controller if needed
  if [[ -w /sys/fs/cgroup/cgroup.subtree_control ]]; then
    sudo sh -c 'echo "+cpu +io +memory +pids" > /sys/fs/cgroup/cgroup.subtree_control' 2>/dev/null || true
  fi
  echo "$p"
}

cg_add_all_postgres(){
  local p; p="$(cg_path)"
  local one
  for one in $(pgrep -x postgres || true); do
    sudo sh -c "echo $one > '$p/cgroup.procs'" 2>/dev/null || true
  done
}

apply_pg_conf(){
  local pgdata="${PGDATA:-$HOME/pgdata}"
  ensure_file "$CONFIG_FILE"
  [[ -d "$pgdata" ]] || die "PGDATA not found: $pgdata"
  cp "$pgdata/postgresql.conf" "$pgdata/postgresql.conf.bak.$(date +%s)"
  cat "$CONFIG_FILE" >> "$pgdata/postgresql.conf"
  pg_ctl -D "$pgdata" restart -m fast
}

run_pg_client(){
  local runner="$REPO_ROOT/postgresql/pgsql_bench.sh"
  ensure_file "$runner"
  # Map wrapper vars expected by your runner
  export WORKLOAD="${WORKLOADS}"
  export ITERATIONS="${ITER}"
  export WARMUP_SECONDS DURATION THREADCOUNT
  bash "$runner"
}

perf_parse_totals_to_json(){
  local raw="$1" out="$2"
  python3 - "$raw" "$out" <<'PY'
import json,sys,re
raw,out=sys.argv[1],sys.argv[2]
m={}
for L in open(raw):
  p=L.strip().split(',')
  if len(p)<3: continue
  try: v=float(p[0])
  except: continue
  k=p[2].strip().lower().replace('-','_').replace(':','_').replace(' ','_')
  m[k]=v
open(out,'w').write(json.dumps(m,indent=2))
print(out)
PY
}

# ---------- SUT: PostgreSQL ----------
run_postgres(){
  local default_cfg="$REPO_ROOT/postgresql/configs/original.conf"
  CONFIG_FILE="${CONFIG_FILE:-$default_cfg}"
  ensure_file "$CONFIG_FILE"

  log "PG: applying config $CONFIG_FILE (jit/shared_buffers/wal knobs here matter for TPS)"
  apply_pg_conf

  local pgdata="${PGDATA:-$HOME/pgdata}"
  pg_ctl -D "$pgdata" -l "$LOG_DIR/pg.log" status >/dev/null 2>&1 || \
    pg_ctl -D "$pgdata" -l "$LOG_DIR/pg.log" start

  local label="pg_${TS}"
  local xml secs; xml="$(pg_resolve_xml_for_workload "$WORKLOADS")"
  secs="$(pg_parse_time_from_xml "$xml")"; [[ -z "$secs" ]] && secs="$DURATION"

  if [[ "$MEASURE_TARGET" != "server_exec" ]]; then
    log "MEASURE_TARGET=$MEASURE_TARGET → falling back to whole-run attach"
  fi

  # Start client first (so connections begin)
  ( run_pg_client ) & RUNNER_PID=$!

  log "Ramping ${RAMP_SECONDS}s to allow backends to spawn…"
  sleep "$RAMP_SECONDS"

  # ---- Choose attach mode ----
  local use_cg=false
  if [[ "$ATTACH_MODE" == "cgroup" || "$ATTACH_MODE" == "auto" ]]; then
    if have_cgroup_v2 && cg_make >/dev/null; then
      use_cg=true
    fi
  fi

  local totals_raw="$LOG_DIR/perf_${label}_raw.txt"
  local totals_json="$LOG_DIR/perf_${label}_summary.json"
  local intervals_csv="$LOG_DIR/perf_${label}_interval.csv"

  if $use_cg; then
    local P="$(cg_path)"
    log "Attaching via cgroup ($P), refreshing membership during window…"
    cg_add_all_postgres
    # background refresher keeps adding any new backends
    ( while kill -0 "$RUNNER_PID" 2>/dev/null; do cg_add_all_postgres; sleep 1; done ) & CGREF_PID=$!

    # perf with interval prints
    ( perf stat -x, -G "${CGROUP_NAME}" -I "${INTERVAL_MS}" -e "${PERF_EVENTS}" -- sleep "${secs}" \
        1> >(awk -vOFS=',' 'BEGIN{print "millis,event,value"} NR>0{print $1,$3,$2}' > "$intervals_csv") \
        2> "$totals_raw" ) || true

    kill "$CGREF_PID" 2>/dev/null || true
  else
    # PID snapshot fallback (documented loudly)
    local pids; pids="$(pg_collect_pids_once)"
    if [[ -z "$pids" ]]; then
      log "Could not find postgres PIDs — measuring client as last resort"
      perf stat -x, -I "${INTERVAL_MS}" -e "${PERF_EVENTS}" -- sleep "${secs}" \
        1> >(awk -vOFS=',' 'BEGIN{print "millis,event,value"} NR>0{print $1,$3,$2}' > "$intervals_csv") \
        2> "$totals_raw" || true
    else
      log "Attaching to PID snapshot: $pids (fallback mode)"
      ( perf stat -x, -p "$pids" -I "${INTERVAL_MS}" -e "${PERF_EVENTS}" -- sleep "${secs}" \
          1> >(awk -vOFS=',' 'BEGIN{print "millis,event,value"} NR>0{print $1,$3,$2}' > "$intervals_csv") \
          2> "$totals_raw" ) || true
    fi
  fi

  wait "$RUNNER_PID" || true
  perf_parse_totals_to_json "$totals_raw" "$totals_json"

  # provenance block for transparency
  cat > "$LOG_DIR/perf_${label}_provenance.txt" <<EOF
timestamp_utc=$TS
sut=postgresql
workload=${WORKLOADS}
xml=${xml}
execute_secs=${secs}
attach_mode=$([[ $use_cg == true ]] && echo "cgroup:${CGROUP_NAME}" || echo "pids-snapshot")
interval_ms=${INTERVAL_MS}
events=${PERF_EVENTS}
config_file=${CONFIG_FILE}
EOF

  log "Done. Intervals → $intervals_csv ; Totals → $totals_json"
}

# ---------- main ----------
case "$SUT" in
  postgresql) run_postgres ;;
  *) die "Only postgresql path is hardened in this version." ;;
esac
log "All runs complete → summaries in $LOG_DIR"
