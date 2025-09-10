#!/usr/bin/env bash
# Reusable parser + CSV writer for LIKWID Roofline runs
# Can be sourced (recommended) or invoked directly.
# When invoked directly:
#   bash parser.sh <OUT_DIR> <G_MEM> <G_CPI> <G_CACHES> <G_L3> <G_L2> <G_L1> <APP_MEASURE_S> <THREADS> [SZS_L1] [SZS_L2] [SZS_L3] [SZS_MEM]
#
# OUT_DIR must contain subdirs: app/ (LIKWID outputs) and roofs/ (likwid-bench outputs).

set -Eeuo pipefail
export LC_ALL=C LANG=C

# -------------------------- parsing helpers --------------------------
get_metric_cell() {
  local pat="$1" file="$2"
  awk -F '|' -v pat="$pat" '
    {
      label = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", label)
      if (label ~ pat) {
        for (i = NF; i >= 1; i--) {
          v = $i
          gsub(/[^0-9.+-eE]/, "", v)
          if (v != "") { print v; exit }
        }
      }
    }' "$file" 2>/dev/null
}

# Prefer overall Memory bandwidth, fallback to Memory read bandwidth
_get_mem_bw_from_file() {
  local f="$1" v
  v="$(get_metric_cell 'Memory[[:space:]]+bandwidth[[:space:]]*\\[(MByte|MBytes)/s\\]' "$f")"
  if [ -z "$v" ]; then
    v="$(get_metric_cell 'Memory[[:space:]]+read[[:space:]]+bandwidth[[:space:]]*\\[(MByte|MBytes)/s\\]' "$f")"
  fi
  [ -n "$v" ] && printf '%s\n' "$v"
}
# Back-compat name (main script used this name earlier)
get_mem_bw_sum() { _get_mem_bw_from_file "$@"; }
get_mem_bw_from_file() { _get_mem_bw_from_file "$@"; }

get_cpi() { get_metric_cell '^[[:space:]]*CPI[[:space:]]*$' "$1"; }
get_ipc() { get_metric_cell '^[[:space:]]*IPC[[:space:]]*$' "$1"; }

get_runtime_s_from_file() {
  local f="$1"
  awk -F '|' '
    /Runtime([[:space:]]*\(RDTSC\))?[[:space:]]*\[s\]/ {
      for (i = NF; i >= 1; i--) {
        v = $i; gsub(/[^0-9.+-eE]/,"",v)
        if (v!=""){ print v; exit }
      }
    }' "$f" 2>/dev/null
}

sum_event() {
  local name_re="$1" file="$2"
  awk -F '|' -v pat="$name_re" '
    $0 ~ pat {
      v=""
      for (i = NF; i >= 1; i--) { t=$i; gsub(/[^0-9.+-eE]/,"",t); if(t!=""){ v=t; break } }
      if (v!="") sum += v + 0
    }
    END { if (sum>0) printf "%.0f\n", sum }
  ' "$file" 2>/dev/null
}

get_instructions_sum() {
  local f="$1"
  local ins cycles cpi ipc

  ins="$(sum_event '(INST(RUCTIONS)?|INSTR)([_.:]?)RETIRED([_.:]?)(ANY([_.:]?P)?|TOTAL)?' "$f")"
  if [ -n "$ins" ]; then echo "$ins"; return 0; fi

  cycles="$(sum_event 'CPU([_.:]?)CLK\1UNHALTED([_.:]?)(CORE|THREAD([_.:]?P)?)?' "$f")"
  cpi="$(get_cpi "$f")"
  ipc="$(get_ipc "$f")"

  if [ -n "$cycles" ] && [ -n "$cpi" ] && awk "BEGIN{exit(!($cpi>0))}"; then
    awk -v c="$cycles" -v p="$cpi" 'BEGIN{printf "%.0f\n", c/p}'; return 0
  fi
  if [ -n "$cycles" ] && [ -n "$ipc" ] && awk "BEGIN{exit(!($ipc>0))}"; then
    awk -v c="$cycles" -v i="$ipc" 'BEGIN{printf "%.0f\n", c*i}'; return 0
  fi
  return 1
}

roof_pick() {
  local f="$1"
  awk '
    /MByte\/s|MBytes\/s/ {
      v=""
      for (i=NF;i>=1;i--) { t=$i; gsub(/[^0-9.+-eE]/,"",t); if(t!=""){ v=t; break } }
      if (v!="") last=v
    }
    END { if (last!="") print last }
  ' "$f" 2>/dev/null
}

# -------------------------- main worker --------------------------
roofline_parse_and_write() {
  local OUT="$1" GMEM="$2" GCPI="$3" GCACHES="$4" GL3="$5" GL2="$6" GL1="$7" \
        APP_MEASURE_S="$8" THREADS="$9"
  shift 9 || true
  local SZS_L1="${1:-32kB}" SZS_L2="${2:-256kB}" SZS_L3="${3:-2MB}" SZS_MEM="${4:-2GB}"

  # --- derive core app metrics (BW, runtime, instructions)
  local BW_MEM="" RT_S="" INSTR="" INSTR_PER_S="" BYTES_PER_S="" INSTR_PER_BYTE=""

  if [ -n "$GMEM" ] && [ -s "$OUT/app/${GMEM}.out" ]; then
    BW_MEM="$(get_mem_bw_from_file "$OUT/app/${GMEM}.out" || true)"
  fi
  if [ -z "$BW_MEM" ] && [ -n "$GCACHES" ] && [ -s "$OUT/app/${GCACHES}.out" ]; then
    BW_MEM="$(get_mem_bw_from_file "$OUT/app/${GCACHES}.out" || true)"
  fi

  if [ -n "$GCPI" ] && [ -s "$OUT/app/${GCPI}.out" ]; then
    RT_S="$(get_runtime_s_from_file "$OUT/app/${GCPI}.out" || true)"
  fi
  : "${RT_S:=$APP_MEASURE_S}"

  if [ -n "$GCPI" ] && [ -s "$OUT/app/${GCPI}.out" ]; then
    INSTR="$(get_instructions_sum "$OUT/app/${GCPI}.out" || true)"
  fi
  if [ -z "$INSTR" ] && [ -n "$GMEM" ] && [ -s "$OUT/app/${GMEM}.out" ]; then
    INSTR="$(get_instructions_sum "$OUT/app/${GMEM}.out" || true)"
  fi
  if [ -z "$INSTR" ] && [ -n "$GCACHES" ] && [ -s "$OUT/app/${GCACHES}.out" ]; then
    INSTR="$(get_instructions_sum "$OUT/app/${GCACHES}.out" || true)"
  fi

  if [ -n "$INSTR" ] && [ -n "$RT_S" ] && [ -n "$BW_MEM" ]; then
    INSTR_PER_S=$(awk -v i="$INSTR" -v t="$RT_S" 'BEGIN{ if(t>0) printf "%.6f", i/t }')
    BYTES_PER_S=$(awk -v m="$BW_MEM" 'BEGIN{ printf "%.6f", m*1024*1024 }')
    INSTR_PER_BYTE=$(awk -v ips="$INSTR_PER_S" -v bps="$BYTES_PER_S" 'BEGIN{ if(bps>0) printf "%.9f", ips/bps }')
  fi

  # --- roofs (if present)
  local ROOF_L1="" ROOF_L2="" ROOF_L3="" ROOF_MEM=""
  [ -s "$OUT/roofs/L1.out" ] && ROOF_L1="$(roof_pick "$OUT/roofs/L1.out")"
  [ -s "$OUT/roofs/L2.out" ] && ROOF_L2="$(roof_pick "$OUT/roofs/L2.out")"
  [ -s "$OUT/roofs/L3.out" ] && ROOF_L3="$(roof_pick "$OUT/roofs/L3.out")"
  [ -s "$OUT/roofs/MEM.out" ] && ROOF_MEM="$(roof_pick "$OUT/roofs/MEM.out")"

  # --- write CSV
  local CSV="$OUT/roofline_summary.csv"
  {
    echo "metric,value,unit,notes"
    echo "app_mem_bandwidth,${BW_MEM},MBytes/s,LIKWID MEM SUM"
    [ -n "$INSTR" ]        && echo "app_instructions,${INSTR},count,Derived from events or cycles/CPI/IPC"
    [ -n "$RT_S" ]         && echo "app_runtime,${RT_S},s,Runtime (RDTSC)"
    [ -n "$INSTR_PER_S" ]  && echo "app_instr_per_sec,${INSTR_PER_S},1/s,Derived"
    [ -n "$INSTR_PER_BYTE" ] && echo "app_instr_per_byte,${INSTR_PER_BYTE},1/byte,Instruction Roofline intensity"
    [ -n "$ROOF_L1" ] && echo "roof_L1,${ROOF_L1},MBytes/s,likwid-bench load_avx ${SZS_L1} ${THREADS}t"
    [ -n "$ROOF_L2" ] && echo "roof_L2,${ROOF_L2},MBytes/s,likwid-bench load_avx ${SZS_L2} ${THREADS}t"
    [ -n "$ROOF_L3" ] && echo "roof_L3,${ROOF_L3},MBytes/s,likwid-bench load_avx ${SZS_L3} ${THREADS}t"
    [ -n "$ROOF_MEM" ] && echo "roof_MEM,${ROOF_MEM},MBytes/s,likwid-bench copy_avx ${SZS_MEM} ${THREADS}t"
  } > "$CSV"

  echo "$CSV"
}

# -------------------------- CLI entrypoint --------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # invoked directly
  if [ "$#" -lt 9 ]; then
    echo "Usage: $0 OUT_DIR G_MEM G_CPI G_CACHES G_L3 G_L2 G_L1 APP_MEASURE_S THREADS [SZS_L1] [SZS_L2] [SZS_L3] [SZS_MEM]"
    exit 1
  fi
  roofline_parse_and_write "$@"
fi
