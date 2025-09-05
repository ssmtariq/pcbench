#!/usr/bin/env bash
# 1_bootstrap.sh — base deps + SuT-aware installers (postgresql|nginx|redis|all)
# Reads SUT from env (set by runner.sh), but also accepts an optional CLI arg.
# Idempotent: safe to re-run; installs exact tools/versions you specified.

set -Eeuo pipefail

log(){ echo -e "[$(date +%T)] $*"; }
ok(){ echo -e "[$(date +%T)] ✅ $*"; }
warn(){ echo -e "[$(date +%T)] ⚠️  $*" >&2; }
die(){ echo -e "[$(date +%T)] ❌ $*" >&2; exit 1; }

# --- Paths / defaults ---
ARTI_ROOT="${ARTI_ROOT:-$HOME/pcbench_runs}"
LOG_DIR="${LOG_DIR:-$ARTI_ROOT/logs}"
THREADS="${THREADS:-$(nproc || echo 8)}"
mkdir -p "$ARTI_ROOT" "$LOG_DIR"

# SUT comes from runner.sh export; allow optional CLI override for standalone use.
SUT_REQ="${1:-${SUT:-none}}"

# --- tiny helpers ---
need(){ command -v "$1" >/dev/null 2>&1; }
apt_has(){ dpkg -s "$1" >/dev/null 2>&1; }
ensure_pkg(){ apt_has "$1" || { log "Installing $1"; sudo apt-get update -y >/dev/null; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"; }; }
ensure_cmd_or_pkg(){ need "$1" || ensure_pkg "$2"; }

# --- Base deps used across the toolchain (unchanged spirit) ---
log "Ensuring base packages"
ensure_pkg build-essential
ensure_pkg cmake
ensure_pkg gfortran
ensure_pkg libssl-dev
ensure_pkg libreadline-dev
ensure_pkg zlib1g-dev
ensure_pkg wget
ensure_pkg curl
ensure_pkg jq
ensure_pkg unzip
ensure_pkg zip
ensure_pkg git
ensure_pkg xmlstarlet
ensure_pkg apache2-utils           # ab (for nginx sanity / quick drive)
ensure_pkg postgresql-client       # psql client
ensure_pkg redis-tools
ensure_pkg redis-server
ensure_pkg openjdk-21-jdk          # general Java (BenchBase needs JDK 23; installed below)
# perf (kernel matching tools)
ensure_cmd_or_pkg perf "linux-tools-$(uname -r)"

# perf permissions (idempotent)
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null || true
sudo sysctl -w kernel.perf_event_paranoid=-1 >/dev/null || true

# HPCToolkit via Spack (same behavior as before)
if [ -d "$HOME/spack" ]; then
  # shellcheck disable=SC1091
  . "$HOME/spack/share/spack/setup-env.sh"
  spack load hpctoolkit >/dev/null 2>&1 || true
fi
if ! command -v hpcrun >/dev/null 2>&1 || ! command -v hpcprof >/dev/null 2>&1; then
  log "Installing HPCToolkit via Spack (first time only)"
  if [ ! -d "$HOME/spack" ]; then git clone https://github.com/spack/spack.git "$HOME/spack"; fi
  # shellcheck disable=SC1091
  . "$HOME/spack/share/spack/setup-env.sh"
  spack external find gcc gfortran cmake || true
  spack external find papi || true
  spack compiler find || true
  spack mirror add binary_mirror https://binaries.spack.io/releases/v0.20 || true
  spack buildcache keys --install --trust || true
  spack install -j"$THREADS" hpctoolkit +papi || spack install -j"$THREADS" hpctoolkit +papi ^intel-xed@2023.10.11
  spack load hpctoolkit || true
fi
command -v hpcrun  >/dev/null 2>&1 && ok "HPCToolkit: $(hpcrun -V | head -n1 2>/dev/null || echo present)"
command -v hpcprof >/dev/null 2>&1 && ok "HPCToolkit DB tools present"

# =============================
# SuT + Benchmark installers
# =============================

install_temurin23(){
  if ! java -version 2>&1 | grep -q '23\.'; then
    log "Installing Temurin JDK 23 (required by BenchBase)"
    ensure_pkg gnupg
    ensure_pkg lsb-release
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | \
      sudo gpg --dearmor -o /usr/share/keyrings/adoptium-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/adoptium-archive-keyring.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | \
      sudo tee /etc/apt/sources.list.d/adoptium.list >/dev/null
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y temurin-23-jdk
  fi
  ok "Java: $(java -version 2>&1 | head -n1)"
}

install_postgres_and_benchbase(){
  # PostgreSQL 16.1 with debug symbols under $HOME/pg16
  if [ ! -x "$HOME/pg16/bin/psql" ]; then
    log "Building PostgreSQL 16.1 with debug symbols"
    cd "$HOME"
    wget -q https://ftp.postgresql.org/pub/source/v16.1/postgresql-16.1.tar.gz
    tar xf postgresql-16.1.tar.gz && cd postgresql-16.1
    ./configure --prefix="$HOME/pg16" --enable-debug CFLAGS="-g -O2 -fno-omit-frame-pointer" --without-icu
    make -j"$THREADS"
    make install
    echo 'export PATH=$HOME/pg16/bin:$PATH' >> "$HOME/.bashrc"
    export PATH="$HOME/pg16/bin:$PATH"
    ok "PostgreSQL installed to \$HOME/pg16"
  else
    ok "PostgreSQL already present at \$HOME/pg16"
  fi

  # Initdb if missing
  if [ ! -d "$HOME/pgdata" ]; then
    log "Initializing PGDATA at ~/pgdata"
    initdb -D "$HOME/pgdata"
  fi

  # Quick smoke: start → version → stop (no persistent service)
  if ! pg_ctl -D "$HOME/pgdata" -l "$LOG_DIR/pglog" status >/dev/null 2>&1; then
    pg_ctl -D "$HOME/pgdata" -l "$LOG_DIR/pglog" start
    psql -c "SELECT version();" || true
    pg_ctl -D "$HOME/pgdata" stop
  fi

  # BenchBase (requires JDK 23)
  if [ ! -f "$HOME/benchbase/target/benchbase-postgres/benchbase.jar" ]; then
    log "Installing BenchBase (postgresql profile)"
    install_temurin23
    cd "$HOME"
    if [ ! -d "$HOME/benchbase" ]; then
      git clone --depth 1 https://github.com/cmu-db/benchbase.git
    fi
    cd benchbase
    ./mvnw clean package -P postgres -T 1C -DskipTests
    cd target
    tar xvzf benchbase-postgres.tgz
    # Symlink configs for convenience
    [ -L "$HOME/config" ] || ln -s "$HOME/benchbase/target/benchbase-postgres/config" "$HOME/config" || true
    ok "BenchBase (postgresql) ready"
  else
    ok "BenchBase already built"
  fi
}

install_nginx_and_wrk(){
  # nginx 1.27.0 with debug under $HOME/nginx
  if ! (nginx -v 2>&1 | grep -q '1\.27'); then
    log "Building nginx 1.27.0 with debug"
    cd "$HOME"
    wget -q http://nginx.org/download/nginx-1.27.0.tar.gz
    tar xf nginx-1.27.0.tar.gz && cd nginx-1.27.0
    export CFLAGS="-g -O2 -fno-omit-frame-pointer"
    ./configure --prefix="$HOME/nginx" --with-http_ssl_module --with-threads --with-file-aio --with-debug
    make -j"$THREADS"
    make install
    echo 'export PATH=$HOME/nginx/sbin:$PATH' >> "$HOME/.bashrc"
    export PATH="$HOME/nginx/sbin:$PATH"
    ok "nginx installed to \$HOME/nginx"
  else
    ok "nginx 1.27 already present ($(nginx -v 2>&1))"
  fi

  # wrk
  if [ ! -x "$HOME/wrk/wrk" ]; then
    log "Installing wrk benchmark tool"
    git clone https://github.com/wg/wrk.git "$HOME/wrk" || true
    cd "$HOME/wrk"
    make -j"$THREADS"
    ok "wrk built"
  else
    ok "wrk already present"
  fi
}

install_redis_and_ycsb(){
  # Redis 7.2.5 under $HOME/redis-7.2
  if [ ! -x "$HOME/redis-7.2/bin/redis-server" ]; then
    log "Building Redis 7.2.5"
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tcl pkg-config libssl-dev
    cd "$HOME"
    wget -q https://download.redis.io/releases/redis-7.2.5.tar.gz
    tar xf redis-7.2.5.tar.gz && cd redis-7.2.5
    make -j"$THREADS" CFLAGS="-O2 -g -fno-omit-frame-pointer"
    sudo make install PREFIX="$HOME/redis-7.2"
    echo 'export PATH=$HOME/redis-7.2/bin:$PATH' >> "$HOME/.bashrc"
    export PATH="$HOME/redis-7.2/bin:$PATH"
    ok "Redis installed to \$HOME/redis-7.2"
  else
    ok "Redis already present at \$HOME/redis-7.2"
  fi

  # vm.overcommit
  if [ "$(sysctl -n vm.overcommit_memory 2>/dev/null || echo 0)" != "1" ]; then
    log "Enabling vm.overcommit_memory=1"
    echo "vm.overcommit_memory=1" | sudo tee /etc/sysctl.d/99-redis-overcommit.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-redis-overcommit.conf >/dev/null || true
  fi

  # YCSB 0.17.0
  if [ ! -d "$HOME/YCSB" ]; then
    log "Installing YCSB 0.17.0"
    cd "$HOME"
    curl -L -o ycsb-0.17.0.tar.gz https://github.com/brianfrankcooper/YCSB/releases/download/0.17.0/ycsb-0.17.0.tar.gz
    tar xfvz ycsb-0.17.0.tar.gz
    mv ycsb-0.17.0 "$HOME/YCSB"
    echo 'export YCSB_DIR=~/YCSB' >> "$HOME/.bashrc"
    export YCSB_DIR="$HOME/YCSB"
    ok "YCSB installed to \$HOME/YCSB"
  else
    ok "YCSB already present"
  fi
}

# --- dispatch based on SUT ---
case "$SUT_REQ" in
  postgresql)
    log "Requested SuT: postgresql → ensure PostgreSQL + BenchBase"
    install_postgres_and_benchbase
    ;;
  nginx)
    log "Requested SuT: nginx → ensure nginx + wrk"
    install_nginx_and_wrk
    ;;
  redis)
    log "Requested SuT: redis → ensure Redis + YCSB"
    install_redis_and_ycsb
    ;;
  all)
    log "Requested SuT: all → ensure all SuTs and their benchmarks"
    install_postgres_and_benchbase
    install_nginx_and_wrk
    install_redis_and_ycsb
    ;;
  none|*)
    # If runner didn't set SUT, do nothing extra beyond base deps.
    warn "No valid SUT specified (got '$SUT_REQ'). Set SUT=postgresql|nginx|redis|all or pass as first arg."
    ;;
esac

ok "Bootstrap complete (SUT=$SUT_REQ). Logs: $LOG_DIR"
