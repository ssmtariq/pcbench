#!/usr/bin/env bash
set -Eeuo pipefail
# Parameters flow to child scripts via env
export SUT="${SUT:-postgres}"
export WORKLOADS="${WORKLOADS:-all}"
export ITER="${ITER:-3}"
export CONF_PATH="${CONF_PATH:-}"
export BENCH_CFG="${BENCH_CFG:-}"
export WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
export DURATION="${DURATION:-180}"
export THREADCOUNT="${THREADCOUNT:-12}"
export CONCURRENCY="${CONCURRENCY:-500}"
export ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
export LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
export BUNDLE_DIR="${BUNDLE_DIR:-$ARTI_ROOT/bundle}"
export HPCRUN_OUT="${HPCRUN_OUT:-$ARTI_ROOT/hpctoolkit_measurements}"
export HPC_DB="${HPC_DB:-$ARTI_ROOT/hpctoolkit_database}"
export ORACLE="${ORACLE:-$ARTI_ROOT/oracle.jsonl}"

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
step(){ echo -e "\n========== $* ==========\n"; }

step "1. Bootstrap"
"$dir/1_bootstrap.sh"

step "2. Perf events snapshot"
"$dir/2_perf_events.sh"

step "3. Run workloads under perf"
"$dir/3_run_workload.sh"

step "4. Classify memory-boundedness"
"$dir/4_classify_memory.sh"

if [ -f "$ARTI_ROOT/memory_confirmed.flag" ] || [ "${FORCE_PROFILE:-0}" = "1" ]; then
  step "5. HPCToolkit profile"
  "$dir/5_hpct_profile.sh"
  step "6. Collect augmentation bundle"
  "$dir/6_collect_aug.sh"
else
  echo "[!] Skipping 40/50 because memory not confirmed (set FORCE_PROFILE=1 to force)."
fi

echo -e "\n(Optionally) put optimized CONF_PATH and run 7_validate.sh to append oracle.\n"

step "8. Status"
"$dir/8_print_status.sh"

echo -e "\n✅ Runner complete.\n"
