#!/usr/bin/env bash
set -Eeuo pipefail
ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
BUNDLE_DIR="${BUNDLE_DIR:-$ARTI_ROOT/bundle}"
ORACLE="${ORACLE:-$ARTI_ROOT/oracle.jsonl}"

echo "Artifacts root: $ARTI_ROOT"
echo "- Perf events:      $ARTI_ROOT/perf_events.txt"
echo "- Perf summaries:   $(ls -1 $LOG_DIR/perf_*_summary.json 2>/dev/null | wc -l) files"
echo "- Classification:   $ARTI_ROOT/memory_classification.csv"
echo "- Memory flag:      $( [ -f $ARTI_ROOT/memory_confirmed.flag ] && echo present || echo missing )"
echo "- HPCToolkit DB:    $( [ -d $ARTI_ROOT/hpctoolkit_database ] && echo present || echo missing )"
echo "- Bundle:           $BUNDLE_DIR"
echo "- Oracle:           $ORACLE (lines: $( [ -f $ORACLE ] && wc -l < $ORACLE || echo 0 ))"
