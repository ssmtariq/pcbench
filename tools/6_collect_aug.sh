#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo -e "[$(date +%T)] $*"; }

ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
BUNDLE_DIR="${BUNDLE_DIR:-$ARTI_ROOT/bundle}"
HPC_DB="${HPC_DB:-$ARTI_ROOT/hpctoolkit_database}"
SUT="${SUT:-postgres}"
CONF_PATH="${CONF_PATH:-}"
THREADS="${THREADS:-$(nproc || echo 8)}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$BUNDLE_DIR"

# 7A: call paths
if [ -d "$HPC_DB" ]; then
  (cd "$(dirname "$HPC_DB")" && zip -qr "${BUNDLE_DIR}/hpctoolkit_db.zip" "$(basename "$HPC_DB")")
fi

# 7B: knobs/docs
case "$SUT" in
  postgres) psql -Atqc "SELECT name, setting, unit, short_desc FROM pg_settings ORDER BY name" > "${BUNDLE_DIR}/pg_knobs.tsv" || true ;;
  nginx)    nginx -T > "${BUNDLE_DIR}/nginx_full_config.txt" 2>&1 || true; nginx -V > "${BUNDLE_DIR}/nginx_version.txt" 2>&1 || true ;;
  redis)    redis-cli CONFIG GET '*' > "${BUNDLE_DIR}/redis_knobs.txt" 2>&1 || true; redis-server --help > "${BUNDLE_DIR}/redis_help.txt" 2>&1 || true ;;
esac

# 7C: source code (best-effort)
case "$SUT" in
  postgres) [ -d "$HOME/postgresql-16.1" ] && (cd "$HOME/postgresql-16.1" && tar czf "${BUNDLE_DIR}/postgresql-16.1_src.tgz" .) || true ;;
  nginx)    set +e; apt-get source -y nginx >/dev/null 2>&1 && tar czf "${BUNDLE_DIR}/nginx_src.tgz" nginx-*; set -e ;;
  redis)    set +e; apt-get source -y redis >/dev/null 2>&1 && tar czf "${BUNDLE_DIR}/redis_src.tgz" redis-*; set -e ;;
esac

[ -n "$CONF_PATH" ] && [ -f "$CONF_PATH" ] && cp "$CONF_PATH" "${BUNDLE_DIR}/current_config.conf" || true
cp -a "$LOG_DIR" "${BUNDLE_DIR}/logs" 2>/dev/null || true

cat > "${BUNDLE_DIR}/prompt_bundle.md" <<EOF
# Context for Config Optimization (Auto-Generated)
- Date: ${TS}
- SUT: ${SUT}

## Perf classification summary (tail)
$(tail -n 50 "${ARTI_ROOT}/memory_classification.csv" 2>/dev/null || echo "No classifications yet.")

## HPCToolkit database
- Attached: hpctoolkit_db.zip

## Knobs docs
- PG: pg_knobs.tsv; Nginx: nginx_full_config.txt; Redis: redis_knobs.txt

## Current config (if provided)
$( [ -f "${BUNDLE_DIR}/current_config.conf" ] && sed -n '1,150p' "${BUNDLE_DIR}/current_config.conf" )

## Ask ChatGPT
Propose an optimized configuration (knobs only) that reduces LLC MPKI and improves throughput without sacrificing correctness for the given workload. Return a drop-in config snippet.
EOF

log "Bundle ready → ${BUNDLE_DIR}"
