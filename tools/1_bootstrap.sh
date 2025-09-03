#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo -e "[$(date +%T)] $*"; }
ok(){ echo -e "[$(date +%T)] ✅ $*"; }
warn(){ echo -e "[$(date +%T)] ⚠️  $*" >&2; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
THREADS="${THREADS:-$(nproc || echo 8)}"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

need(){ command -v "$1" >/dev/null 2>&1; }
apt_has(){ dpkg -s "$1" >/dev/null 2>&1; }
ensure_pkg(){ apt_has "$1" || (log "Installing $1"; sudo apt-get update -y >/dev/null; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"); }
ensure_cmd_or_pkg(){ need "$1" || ensure_pkg "$2"; }

# === Version helpers + summary registry ===
get_pkg_version(){
  dpkg-query -W -f='${Version}\n' "$1" 2>/dev/null || echo "unknown"
}
get_cmd_version(){
  local c="$1"
  # Try common flags, return first non-empty line
  for flag in "--version" "-V" "-v"; do
    if "$c" $flag >/dev/null 2>&1; then
      "$c" $flag 2>&1 | head -n1 | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' && return 0
    fi
  done
  # Last resort: print file path as a hint
  command -v "$c" 2>/dev/null || echo "unknown"
}
print_row(){ printf "  %-24s | %-9s | %s\n" "$1" "$2" "$3"; }

declare -a DEP_ORDER=()
declare -A DEP_STATUS=()
declare -A DEP_VERSION=()

record_dep(){
  # $1=name, $2=status (Found/Installed), $3=version
  local name="$1" status="$2" ver="$3"
  DEP_ORDER+=("$name")
  DEP_STATUS["$name"]="$status"
  DEP_VERSION["$name"]="$ver"
}

# === Track ensured dependencies (cmds) ===
track_cmd(){
  # $1=cmd, $2=pkg (fallback)
  local cmd="$1" pkg="$2" status ver
  if need "$cmd"; then
    ensure_cmd_or_pkg "$cmd" "$pkg"
    status="Found"
  else
    ensure_cmd_or_pkg "$cmd" "$pkg"
    status="Installed"
  fi
  ver="$(get_cmd_version "$cmd")"
  record_dep "$cmd" "$status" "$ver"
}

# === Track ensured dependencies (pkgs) ===
track_pkg(){
  # $1=pkg
  local pkg="$1" status ver
  if apt_has "$pkg"; then
    ensure_pkg "$pkg"
    status="Found"
  else
    ensure_pkg "$pkg"
    status="Installed"
  fi
  ver="$(get_pkg_version "$pkg")"
  record_dep "$pkg" "$status" "$ver"
}

log "Ensuring base packages"
track_cmd jq jq
track_cmd python3 python3
track_cmd pip pip
track_cmd zip zip
track_cmd unzip unzip
track_cmd git git
track_cmd perf "linux-tools-$(uname -r)"
track_cmd xmlstarlet xmlstarlet
track_pkg default-jdk
track_cmd mvn maven
track_pkg apache2-utils         # ab
track_pkg postgresql-client     # psql client
track_pkg redis-tools
track_pkg redis-server
track_cmd wget wget
track_pkg build-essential
track_pkg cmake
track_pkg gfortran
track_pkg libssl-dev
track_pkg libreadline-dev
track_pkg zlib1g-dev
track_pkg openjdk-21-jdk

log "Enabling perf events (idempotent)"
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null || true
sudo sysctl -w kernel.perf_event_paranoid=-1 >/dev/null || true

if [ -d "$HOME/spack" ]; then
  . "$HOME/spack/share/spack/setup-env.sh"
  spack load hpctoolkit >/dev/null 2>&1 || true
fi

if command -v hpcrun >/dev/null 2>&1 && command -v hpcprof >/dev/null 2>&1; then
  ok "HPCToolkit present"
else
  log "Installing HPCToolkit via Spack (skipped next time)"
  if [ ! -d "$HOME/spack" ]; then git clone https://github.com/spack/spack.git "$HOME/spack"; fi
  . "$HOME/spack/share/spack/setup-env.sh"
  spack external find gcc gfortran cmake || true
  spack external find papi || true
  spack compiler find || true
  spack mirror add binary_mirror https://binaries.spack.io/releases/v0.20 || true
  spack buildcache keys --install --trust || true
  spack install -j"$THREADS" hpctoolkit +papi || spack install -j"$THREADS" hpctoolkit +papi ^intel-xed@2023.10.11
  spack load hpctoolkit
fi

# Record HPCToolkit tools if present (non-fatal if not)
if command -v hpcrun >/dev/null 2>&1; then
  record_dep "hpcrun" "Found" "$(get_cmd_version hpcrun)"
fi
if command -v hpcprof >/dev/null 2>&1; then
  record_dep "hpcprof" "Found" "$(get_cmd_version hpcprof)"
fi

ok "Bootstrap complete. Logs: $LOG_DIR"

# === Summary ===
echo
echo "Dependency Summary:"
echo "  Name                     | Status    | Version / Info"
echo "  -------------------------+-----------+----------------------------------------"
for name in "${DEP_ORDER[@]}"; do
  print_row "$name" "${DEP_STATUS[$name]}" "${DEP_VERSION[$name]}"
done

# Show any HPCToolkit rows that were appended later (avoid duplicates if already in order)
for h in hpcrun hpcprof; do
  if [[ -n "${DEP_STATUS[$h]:-}" ]]; then
    # Check if present in DEP_ORDER already
    found_in_order=false
    for n in "${DEP_ORDER[@]}"; do
      if [[ "$n" == "$h" ]]; then found_in_order=true; break; fi
    done
    if ! $found_in_order; then
      print_row "$h" "${DEP_STATUS[$h]}" "${DEP_VERSION[$h]}"
    fi
  fi
done
