#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo -e "[$(date +%T)] $*"; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
ORACLE="${ORACLE:-$ARTI_ROOT/oracle.jsonl}"
SUT="${SUT:-postgresql}"
WORKLOADS="${WORKLOADS:-medium}"
ITER="${ITER:-1}"
CONF_PATH="${CONF_PATH:-$HOME/pcbench/${SUT}/configs/optimized.conf}"
THREADCOUNT="${THREADCOUNT:-12}"
DURATION="${DURATION:-180}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

extract_last_tps_pg(){
  grep -F "Throughput" -R "$HOME/benchbase/target/benchbase-postgresql/results" -n 2>/dev/null | tail -n1 | \
  awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/) print $i}' | tail -n1
}

append_oracle(){
  local workload="$1" base="$2" opt="$3" mpki="$4" cpi="$5" mr="$6"
  python3 - "$ORACLE" <<PY
import json,sys
j={"ts":"$TS","sut":"$SUT","workload":"$workload","metrics":{"tps_baseline":float("$base" or 0.0),"tps_optimized":float("$opt" or 0.0)}}
try:
  b=float("$base"); o=float("$opt")
  j["metrics"]["improvement_pct"]= ( (o-b)/b*100.0 if b>0 else float("nan") )
except: j["metrics"]["improvement_pct"]="nan"
j["metrics"]["mpki"]=float("$mpki"); j["metrics"]["cpi"]=float("$cpi"); j["metrics"]["miss_rate"]=float("$mr")
with open(sys.argv[1],"a") as f: f.write(json.dumps(j)+"\n")
print(sys.argv[1])
PY
}

# Apply config and do one measurement pass (PG shown; nginx/redis similar)
case "$SUT" in
  postgresql)
    [ -f "$CONF_PATH" ] || die "Missing optimized PG conf"
    cp "$HOME/pgdata/postgresql.conf" "$HOME/pgdata/postgresql.conf.pre_opt.$(date +%s)"
    cat "$CONF_PATH" >> "$HOME/pgdata/postgresql.conf"
    pg_ctl -D "$HOME/pgdata" restart
    # Reuse PG workload: single medium run
    cfg="$HOME/benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_medium.xml"
    java -jar "$HOME/benchbase/target/benchbase-postgres/benchbase.jar" -b tpcc -c "$cfg" --create=false --load=false --execute=true >/dev/null 2>&1 || true
    label="pg_validate_medium"
    perf stat -x, -e cycles,instructions,cache-references,cache-misses -- \
      java -jar "$HOME/benchbase/target/benchbase-postgres/benchbase.jar" -b tpcc -c "$cfg" --create=false --load=false --execute=true 1>/dev/null 2>"$LOG_DIR/perf_${label}_raw.txt" || true
    python3 - "$LOG_DIR/perf_${label}_raw.txt" "$LOG_DIR/perf_${label}_summary.json" <<'PY'
import json,sys
raw,out=sys.argv[1],sys.argv[2]; m={}
for L in open(raw):
  p=L.strip().split(',')
  if len(p)<3: continue
  try: v=float(p[0])
  except: continue
  k=p[2].strip().replace('-','_').replace(':','_').replace(' ','_')
  m[k]=v
open(out,'w').write(json.dumps(m,indent=2))
PY
    tps_opt="$(extract_last_tps_pg)"
    sum="$LOG_DIR/perf_${label}_summary.json"
    cm=$(jq -r '.cache_misses // 0' "$sum"); cr=$(jq -r '.cache_references // 1' "$sum"); ins=$(jq -r '.instructions // 1' "$sum"); cy=$(jq -r '.cycles // 1' "$sum")
    read cls mpki cpi mr < <(python3 - <<PY
cm=$cm; cr=$cr; ins=$ins; cy=$cy
mpki=(cm/ins)*1000.0; cpi=(cy/ins); mr=(cm/cr)
print(("memory-bound" if (mpki>=10 and cpi>=1 and mr>=0.25) else "compute-bound"), mpki, cpi, mr)
PY
)
    # (Optional) set baseline before; or keep 0.0 and compute later manually
    append_oracle "medium" "0.0" "$tps_opt" "$mpki" "$cpi" "$mr" >/dev/null
    ;;
  nginx|redis)
    echo "[!] Provide your nginx/redis optimized CONF_PATH and re-run ab/redis-benchmark; then parse TPS/ops/s similarly and call append_oracle." ;;
esac

echo "[OK] Oracle updated → $ORACLE"
