#!/usr/bin/env bash
# pcbench_deps_install.sh
# Unified dependency installer for CloudLab xl170 (Ubuntu 22.04)

set -Eeuo pipefail

# ---------- helpers ----------
log()  { printf "\n\033[1;34m[STEP]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[NOTE]\033[0m %s\n" "$*"; }
fail_report() {
  printf "\n\033[1;31m[FAIL]\033[0m Command failed at line %s:\n  %s\n\n" "$1" "$2"
  exit 1
}
trap 'fail_report "${LINENO}" "${BASH_COMMAND}"' ERR

# For speed, avoid apt prompts
export DEBIAN_FRONTEND=noninteractive

# ---------- 1) Enable Performance Counters ----------
enable_perf_counters() {
  log "Enable performance counters (per boot)"
  sudo sysctl -w kernel.perf_event_paranoid=-1
  sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'
  ok "perf_event_paranoid is now $(cat /proc/sys/kernel/perf_event_paranoid)"
}

# ---------- 2) Python 3.11 + pip ----------
install_python() {
  if command -v python3.11 >/dev/null 2>&1; then
    ok "Python 3.11 already present: $(python3.11 -V)"
    return
  fi
  log "Install Python 3.11 + venv + distutils + pip (via deadsnakes PPA)"
  sudo add-apt-repository ppa:deadsnakes/ppa -y
  sudo apt update
  sudo apt -y upgrade
  sudo apt install -y python3.11 python3.11-venv python3.11-distutils python3-pip
  ok "Installed $(python3.11 -V)"
}

# ---------- 3) Java 21 ----------
install_java() {
  if command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -q '"21\.'; then
    ok "Java already present: $(java -version 2>&1 | head -n1)"
    return
  fi
  log "Install OpenJDK 21"
  sudo apt install -y openjdk-21-jdk
  ok "Installed $(java -version 2>&1 | head -n1)"
}

# ---------- 4) Docker CE (+ Compose plugin) ----------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker already present: $(docker --version)"
  else
    log "Install Docker CE (latest) and Compose plugin"
    sudo apt remove -y docker docker-engine docker.io containerd runc || true
    sudo apt install -y ca-certificates curl gnupg lsb-release
    sudo mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
      sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ok "Installed Docker: $(docker --version)"
  fi
  # Group add (login required to take effect)
  if ! id -nG "$USER" | grep -q '\bdocker\b'; then
    log "Add $USER to docker group (will require re-login)"
    sudo usermod -aG docker "$USER"
  fi
  warn "If this is your first Docker install, log out/in (or reboot) so group changes apply."
}

# ---------- 5) fio, stress-ng, linux-tools ----------
install_utils() {
  log "Install fio, stress-ng, linux-tools"
  sudo apt install -y fio stress-ng linux-tools-common "linux-tools-$(uname -r)"
  ok "Installed workload tools"
}

# ---------- 6) Miniconda to /mydata/miniconda3 ----------
install_miniconda() {
  local CONDA_DIR=/mydata/miniconda3
  if [ -x "${CONDA_DIR}/bin/conda" ]; then
    ok "Miniconda already present at ${CONDA_DIR}"
  else
    log "Install Miniconda to ${CONDA_DIR}"
    sudo chown -R "$USER" /mydata || true
    pushd /mydata >/dev/null
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda.sh
    bash miniconda.sh -b -p "${CONDA_DIR}"
    popd >/dev/null
    ok "Miniconda installed: ${CONDA_DIR}"
  fi
  # Shell init (future shells)
  if ! grep -q "${CONDA_DIR}/bin" ~/.bashrc 2>/dev/null; then
    echo "export PATH=${CONDA_DIR}/bin:\$PATH" >> ~/.bashrc
  fi
  # Initialize conda for bash (idempotent)
  # shellcheck disable=SC1091
  source "${CONDA_DIR}/etc/profile.d/conda.sh"
  conda init bash >/dev/null 2>&1 || true
}

# ---------- 7) HPCToolkit via Spack (+ PAPI) ----------
install_hpctoolkit_spack() {
  log "Install prerequisites & Spack"
  sudo apt update
  sudo apt -y install git build-essential cmake gfortran \
      libssl-dev libreadline-dev zlib1g-dev openjdk-21-jdk

  if [ ! -d "${HOME}/spack" ]; then
    git clone https://github.com/spack/spack.git "${HOME}/spack"
  fi

  # shellcheck disable=SC1091
  . "${HOME}/spack/share/spack/setup-env.sh"
  if ! grep -q 'spack/share/spack/setup-env.sh' ~/.bashrc 2>/dev/null; then
    echo ". ${HOME}/spack/share/spack/setup-env.sh" >> ~/.bashrc
  fi

  log "Configure Spack externals & cache (gcc/gfortran/cmake/papi)"
  spack external find gcc gfortran cmake || true
  spack external find papi || true
  spack compiler find || true
  spack mirror add binary_mirror https://binaries.spack.io/releases/v0.20 || true
  spack buildcache keys --install --trust || true

  # helper: cleanup between attempts
  spack_cleanup() {
    warn "Cleaning up partial builds before retry"
    spack uninstall -y -f hpctoolkit || true
    spack clean -a || true
  }

  # --- Attempt 1: pinned intel-xed ---
  log "Install HPCToolkit (+papi) with pinned intel-xed [attempt 1]"
  if spack install -j8 hpctoolkit +papi ^intel-xed@2023.10.11; then
    :
  else
    spack_cleanup

    # --- Attempt 2: plain +papi ---
    log "Install HPCToolkit (+papi) plain [attempt 2]"
    if spack install -j8 hpctoolkit +papi; then
      :
    else
      spack_cleanup

      # --- Attempt 3: disable xed ---
      log "Install HPCToolkit (+papi) without xed [attempt 3]"
      if spack install -j8 hpctoolkit +papi ~xed; then
        :
      else
        printf "\n\033[1;31m[FAIL]\033[0m HPCToolkit installation failed after 3 attempts.\n"
        exit 1
      fi
    fi
  fi

  spack load hpctoolkit
  if ! command -v hpcrun >/dev/null 2>&1; then
    printf "\n\033[1;31m[FAIL]\033[0m HPCToolkit appears not loaded after install.\n"
    exit 1
  fi
  ok "HPCToolkit loaded: $(hpcrun -V 2>&1 | head -n1)"
}

# ---------- run all ----------
main() {
  enable_perf_counters
  install_python
  install_java
  install_docker
  install_utils
  install_miniconda
  install_hpctoolkit_spack
  ok "All steps completed"
  printf "\n\033[1;36m[SUMMARY]\033[0m Installed versions:\n"
  command -v python3.11 >/dev/null 2>&1 && python3.11 -V
  command -v java >/dev/null 2>&1 && java -version 2>&1 | head -n1
  command -v docker >/dev/null 2>&1 && docker --version
  command -v docker >/dev/null 2>&1 && docker compose version 2>/dev/null || true
  command -v fio >/dev/null 2>&1 && fio --version
  command -v stress-ng >/dev/null 2>&1 && stress-ng --version | head -n1
  command -v hpcrun >/dev/null 2>&1 && hpcrun -V 2>&1 | head -n1
}
main "$@"
