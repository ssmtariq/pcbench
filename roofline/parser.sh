#!/usr/bin/env bash
# Reusable parser + CSV writer for LIKWID Roofline runs
# Can be sourced (recommended) or invoked directly.
# When invoked directly:
#   bash parser.sh <OUT_DIR> <G_MEM> <G_CPI> <G_CACHES> <G_L3> <G_L2> <G_L1> <APP_MEASURE_S> <THREADS> [SZS_L1] [SZS_L2] [SZS_L3] 
#   [SZS_MEM] [CORES_SPEC] [MAX_IPC] [ROOF_KERNEL_CACHE] [ROOF_KERNEL_MEM] [PEAK_WS]
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

# -------------------------- CPU Roofline helpers ----------------------------------------
peakflops_pick() {
  local f="$1"
  awk '
    /MFLOP\/s|MFlop\/s|MFLOPS/ {
      v=""; for (i=NF;i>=1;i--) { t=$i; gsub(/[^0-9.+-eE]/,"",t); if(t!=""){ v=t; break } }
      if (v!="") last=v
    }
    END { if (last!="") print last }
  ' "$f" 2>/dev/null
}

corespec_count() {
  # Accepts CORES spec like "2" or "2-3" or "2-3,5,7-9"
  local spec="$1"
  [ -z "$spec" ] && { echo 1; return; }
  awk -v s="$spec" 'BEGIN{
    n=0; gsub(/ /,"",s);
    split(s,a,",");
    for(i in a){
      if (a[i] ~ /^[0-9]+$/){ n++; }
      else if (a[i] ~ /^[0-9]+-[0-9]+$/){
        split(a[i],r,"-"); n += (r[2]-r[1]+1);
      }
    }
    if (n<1) n=1;
    print n;
  }'
}

max_freq_hz() {
  # Try sysfs (kHz), then /proc/cpuinfo (MHz). Returns Hz.
  local k sys
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    sys="$cpu/cpufreq/cpuinfo_max_freq"
    if [ -r "$sys" ]; then
      k="$(cat "$sys" 2>/dev/null | tr -d '[:space:]')"
      if [ -n "$k" ]; then awk -v khz="$k" 'BEGIN{ printf "%.0f\n", khz*1000 }'; return 0; fi
    fi
  done
  # Fallback: highest "cpu MHz" seen
  awk -F: '/cpu MHz/ { gsub(/[[:space:]]+/,"",$2); if($2+0>mx) mx=$2+0 } END{ if(mx>0) printf "%.0f\n", mx*1e6 }' /proc/cpuinfo 2>/dev/null
}

# -------------------------- main worker --------------------------
roofline_parse_and_write() {
  local OUT="$1" GMEM="$2" GCPI="$3" GCACHES="$4" GL3="$5" GL2="$6" GL1="$7" \
        APP_MEASURE_S="$8" THREADS="$9"
  shift 9 || true
  local SZS_L1="${1:-32kB}" SZS_L2="${2:-256kB}" SZS_L3="${3:-2MB}" SZS_MEM="${4:-2GB}"
  local CORES_SPEC="${5:-}" MAX_IPC_OPT="${6:-}" ROOFK_CACHE="${7:-}" ROOFK_MEM="${8:-}" PEAK_WS="${9:-}"
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

  # --- NEW: compute roofs
  local ROOF_FP_MFLOPS="" ROOF_INSTR_PER_S_EST=""
  [ -s "$OUT/roofs/PEAKFLOPS.out" ] && ROOF_FP_MFLOPS="$(peakflops_pick "$OUT/roofs/PEAKFLOPS.out" || true)"

  # Instruction/s estimate = MAX_IPC * max_freq_hz * #cores
  # Defaults: MAX_IPC=4.0 if not provided; #cores from CORES_SPEC (or 1); freq from sysfs/proc
  if true; then
    local ipc="${MAX_IPC_OPT:-4.0}"
    local cores="$(corespec_count "${CORES_SPEC:-}")"
    local freq_hz="$(max_freq_hz || true)"
    if [ -n "$ipc" ] && [ -n "$cores" ] && [ -n "$freq_hz" ]; then
      ROOF_INSTR_PER_S_EST="$(awk -v a="$ipc" -v c="$cores" -v f="$freq_hz" 'BEGIN{ printf "%.3f", a*c*f }')"
    fi
  fi

  # --- write CSV
  local CSV="$OUT/roofline_summary.csv"
  {
    echo "metric,value,unit,notes"
    echo "app_mem_bandwidth,${BW_MEM},MBytes/s,LIKWID MEM SUM"
    [ -n "$INSTR" ]          && echo "app_instructions,${INSTR},count,Derived from events or cycles/CPI/IPC"
    [ -n "$RT_S" ]           && echo "app_runtime,${RT_S},s,Runtime (RDTSC)"
    [ -n "$INSTR_PER_S" ]    && echo "app_instr_per_sec,${INSTR_PER_S},1/s,Derived"
    [ -n "$INSTR_PER_BYTE" ] && echo "app_instr_per_byte,${INSTR_PER_BYTE},1/byte,Instruction Roofline intensity"
    [ -n "$ROOF_L1" ]        && echo "roof_L1,${ROOF_L1},MBytes/s,likwid-bench ${ROOFK_CACHE:-load_avx} ${SZS_L1} ${THREADS}t"
    [ -n "$ROOF_L2" ]        && echo "roof_L2,${ROOF_L2},MBytes/s,likwid-bench ${ROOFK_CACHE:-load_avx} ${SZS_L2} ${THREADS}t"
    [ -n "$ROOF_L3" ]        && echo "roof_L3,${ROOF_L3},MBytes/s,likwid-bench ${ROOFK_CACHE:-load_avx} ${SZS_L3} ${THREADS}t"
    [ -n "$ROOF_MEM" ]       && echo "roof_MEM,${ROOF_MEM},MBytes/s,likwid-bench ${ROOFK_MEM:-copy_avx} ${SZS_MEM} ${THREADS}t"
    # NEW optional rows:
    [ -n "$ROOF_FP_MFLOPS" ]       && echo "roof_compute_fp_mflops,${ROOF_FP_MFLOPS},MFLOP/s,likwid-bench peakflops_avx_fma ${PEAK_WS:-20kB} ${THREADS}t"
    [ -n "$ROOF_INSTR_PER_S_EST" ] && echo "roof_compute_instr_per_sec_est,${ROOF_INSTR_PER_S_EST},1/s,est MAX_IPC*max_freq_hz*#cores (MAX_IPC=${MAX_IPC_OPT:-4.0})"
  } > "$CSV"

  echo "$CSV"
}

# -------------------------- CLI entrypoint --------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # invoked directly
  if [ "$#" -lt 9 ]; then
    echo "Usage: $0 OUT_DIR G_MEM G_CPI G_CACHES G_L3 G_L2 G_L1 APP_MEASURE_S THREADS [SZS_L1] [SZS_L2] [SZS_L3] [SZS_MEM] [CORES_SPEC] [MAX_IPC] [ROOF_KERNEL_CACHE] [ROOF_KERNEL_MEM] [PEAK_WS]"
    exit 1
  fi
  roofline_parse_and_write "$@"
fi
