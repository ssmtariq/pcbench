# Redis Cache Profiling and Tuning with TUNA on CloudLab xl170

This guide walks you through reproducing the TUNA workflow for
**redis-7.2** on a CloudLab **xl170** node. You will build redis from
source with debug symbols, select a high‑performing configuration from
TUNA's sample runs, profile the server with **HPCToolkit** and **PAPI**,
and then iteratively optimize and re‑evaluate the configuration using
the provided benchmarking script. 

> This file only includes **Redis-specific** steps. For **common setup**
> (node reservation, perf counters, Spack+HPCToolkit install, Java/conda, etc.)
> follow the original README.md sections you already have in the base directory of this repo:
> * “Reserve and Prepare the Node” + enabling hardware counters
> * Installing HPCToolkit via Spack
> 
> See: README.md §§1–3 for perf counters & HPCToolkit install.  
> (Then return here to continue with Redis.) 

---

## 0. Pre-req: make sure perf counters & HPCToolkit are ready

From the base README.md:
- Enable `perf_event_paranoid` (per boot).
- Install & `spack load hpctoolkit` (HPCToolkit + PAPI).  
Return here when `hpcrun`, `hpcstruct`, `hpcprof` are in `$PATH`.

---

## 1. Build and install Redis 7.2 **with symbols**

```bash
# Deps (typical build deps)
sudo apt-get update
sudo apt-get install -y build-essential tcl pkg-config libssl-dev

# Fetch and build Redis 7.2 (or latest 7.x)
cd ~
wget https://download.redis.io/releases/redis-7.2.5.tar.gz
tar xf redis-7.2.5.tar.gz && cd redis-7.2.5

# Build with frame pointers for good callpaths in HPCToolkit
make -j8 CFLAGS="-O2 -g -fno-omit-frame-pointer"
sudo make install PREFIX=$HOME/redis-7.2  # installs to ~/redis-7.2/bin

# Make available in PATH
echo 'export PATH=$HOME/redis-7.2/bin:$PATH' >> ~/.bashrc
export PATH=$HOME/redis-7.2/bin:$PATH

# Sanity check
redis-server --version
````

> Notes
> – Official instructions for building from source on Ubuntu Jammy are here; the
> commands above follow the same flow (install deps → make → install).
> – Keep `-g -fno-omit-frame-pointer` to produce high-quality call paths.

---

## 2. Install a workload generator (we’ll use **memtier\_benchmark**)

Option A — build from source (works reliably on xl170):

```bash
sudo apt-get install -y autoconf automake libtool \
    build-essential libpcre3-dev libevent-dev pkg-config zlib1g-dev libssl-dev git

cd ~
git clone https://github.com/RedisLabs/memtier_benchmark.git
cd memtier_benchmark
autoreconf -ivf
./configure
make -j8
sudo make install  # installs memtier_benchmark into /usr/local/bin
which memtier_benchmark
```

Option B — use `redis-benchmark` (ships with Redis). This is fine for smoke-tests,
but use **memtier** for realistic multi-threaded, pipelined workloads.

---

## 3. Select the **best TUNA Redis config** from `src/results_redis/full_seed1.csv`

```bash
# In your repo root (where this script lives), run:
python3 best_redisconfig_finder.py \
  --csv src/results_redis/full_seed1.csv \
  --out-json TUNA_best_redis_config.json \
  --out-conf TUNA_best_redis_config.conf

# Outputs:
#  - TUNA_best_redis_config.json  (machine-readable)
#  - TUNA_best_redis_config.conf  (redis.conf-style, ready to run)
```

> This mirrors your Postgres config selector: read a CSV, choose the row with the
> **best reported performance**, and emit a config the server can consume.

---

## 4. **Profile Redis** with HPCToolkit (cache-miss sampling)

> We wrap **redis-server** with `hpcrun` and then drive load with memtier.

```bash
# Stop any running instance
redis-cli shutdown nosave 2>/dev/null || true

# Where to store HPCToolkit measurements
export HPCRUN_OUT=$HOME/hpctoolkit-redis-measurements
export HPCRUN_TMPDIR=$HPCRUN_OUT

# Start redis-server under hpcrun, using the selected TUNA config
hpcrun -o "$HPCRUN_OUT" \
       -e PAPI_L2_TCM@100000 \
       -e PAPI_L3_TCM@100000 \
       -- redis-server $HOME/TUNA_best_redis_config.conf --port 6379 --protected-mode no
```

In another terminal, **drive the workload** while `hpcrun` is active:

```bash
memtier_benchmark -s 127.0.0.1 -p 6379 \
  --test-time=180 --threads=4 --clients=25 --pipeline=32 \
  --ratio=1:1 --data-size=512 --key-minimum=1 --key-maximum=500000
```

Stop the server when done:

```bash
redis-cli shutdown nosave
```

**Build the performance database for hpcviewer**:

```bash
# 1) Structural analysis (DWARF) for redis-server binary and measurements
hpcstruct -j 8 $(command -v redis-server)
hpcstruct -j 8 "$HPCRUN_OUT"

# 2) Correlate measurements with sources/binaries
hpcprof -j 8 -S $HOME/redis-server.hpcstruct -o $HOME/hpctoolkit-redis-database "$HPCRUN_OUT"
```

---

## 5. Evaluate the **ORIGINAL (selected) TUNA config**

Use the Redis benchmarking runner (warmup + N runs + summary):

```bash
chmod +x workload_runner_redis.sh
./workload_runner_redis.sh \
  2>&1 | tee ~/redis_original_benchmark.log
```

This script:

* starts `redis-server` with `TUNA_best_redis_config.conf`,
* runs a short warmup,
* runs **N iterations** of a timed memtier workload,
* reports **median/mean/stdev** and appends to `~/redis_bench_results.log`.

---

## 6. Inspect hotspots in **hpcviewer** and iterate configs

Export your hpctoolkit database and open it locally in **hpcviewer**.
Capture screenshots of top L2/L3-miss call paths (e.g., dict/listpack ops,
AOF I/O paths, defrag, rehash). Use those images to ask ChatGPT for a
config-level hypothesis (e.g., `hash-max-listpack-*`, `activedefrag`,
AOF rewrite/fsync cadence).

---

## 7. Evaluate your **OPTIMIZED** config

Save your tweaks as `redis_optimized.conf`, then run the same benchmark:

```bash
REDIS_CONF=$HOME/redis_optimized.conf ./workload_runner_redis.sh \
  2>&1 | tee ~/redis_optimized_benchmark.log
```

Compare median ops/sec and variance to the ORIGINAL run.

---

## 8. Tips

* For realistic high throughput, prefer **multiple threads + clients + pipelining**.
* Keep `-fno-omit-frame-pointer` in Redis build flags for callpath fidelity.
* Pinning the server to specific cores and isolating background noise helps
  reduce throughput variance.
