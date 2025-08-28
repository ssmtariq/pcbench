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

#enable over commit
sudo sysctl vm.overcommit_memory=1
```

> Notes
> – Official instructions for building from source on Ubuntu Jammy are here; the
> commands above follow the same flow (install deps → make → install).
> – Keep `-g -fno-omit-frame-pointer` to produce high-quality call paths.

---

## 2. Select the **best TUNA Redis config** from `src/results_redis/full_seed1.csv`

```bash
cd ~
# Ensure pcbench is already present in your home directory
pip install pandas
python3 pcbench/redis/best_redisconfig_finder.py

# The script writes the following files to home directory as:
#  - TUNA_best_redis_config.json  (machine-readable)
#  - TUNA_best_redis_config.conf  (redis.conf-style, ready to run)
```

---

## 3. Install YCSB workload generator

TUNA’s Redis experiments rely on the Yahoo Cloud Serving Benchmark (YCSB)
to generate load. YCSB is a Java‑based tool that supports many databases 
(including Redis) and allows you to specify
properties such as the number of records, operations and worker threads.
The benchmark description bundled with TUNA (`ycsb.json`) defines
workloada with a warm‑up of 30 s, a benchmark duration of 300 s and
workload properties such as recordcount 1.8 million,
operationcount 2 billion and threadcount 40.
Note: YCSB Workload A is an update heavy workload

Follow these steps to build and install YCSB:
### 3A. Install Java and Maven. 
YCSB requires a recent JDK and Maven 3 to build from source

```bash
sudo apt-get update
sudo apt-get install -y openjdk-11-jdk maven git
```

### 3B. Use a pre‑built release. 
If you prefer not to build from source, the YCSB project publishes tarball releases. 
Downloading and unpacking a release follows the example in the YCSB README

```bash
curl -L -o ycsb-0.17.0.tar.gz \
  https://github.com/brianfrankcooper/YCSB/releases/download/0.17.0/ycsb-0.17.0.tar.gz
tar xfvz ycsb-0.17.0.tar.gz
mv ycsb-0.17.0 ~/YCSB
echo 'export YCSB_DIR=~/YCSB' >> ~/.bashrc
export YCSB_DIR=~/YCSB
```

Quick YCSB Sanity Check

```bash
REDIS_CONF=$HOME/pcbench/redis/configs/TUNA_best_redis_config.conf \
RECORDCOUNT=100000 OPERATIONCOUNT=2000000000 \
WARMUP_SECONDS=0 ITERATIONS=1 DURATION=30 THREADS=10 \
bash $HOME/pcbench/redis/redis_bench.sh
```
With YCSB built or unpacked, you’re ready to run the benchmarks.

### 3C. (Optional) Clone and build YCSB. 
Clone the upstream repository and compile
only the Redis binding. The YCSB README notes that building the full
distribution uses `mvn clean package`, while a single binding can
be compiled with the `-pl` option

```bash
cd ~
git clone https://github.com/brianfrankcooper/YCSB.git
cd YCSB
# Build only the Redis binding to reduce dependencies
mvn -pl site.ycsb:redis-binding -am clean package
```
When the build completes, the launcher script `bin/ycsb.sh` will be
available under your `~/YCSB` directory. All workload templates are
located under `~/YCSB/workloads`. It’s convenient to export
`YCSB_DIR=~/YCSB` so the benchmarking scripts can find it.

---

## 4. **Profile Redis** with HPCToolkit (cache-miss sampling)

### 4A. We wrap **redis-server** with `hpcrun` and then drive load with YCSB.

```bash
# Stop any running instance
redis-cli shutdown nosave 2>/dev/null || true

# Preload the dataset once 
REDIS_CONF=$HOME/pcbench/redis/configs/TUNA_best_redis_config.conf \
RECORDCOUNT=1800000 OPERATIONCOUNT=2000000000 \
WARMUP_SECONDS=0 ITERATIONS=0 DURATION=0 THREADS=10 \
SKIP_LOAD=0 \
bash $HOME/pcbench/redis/redis_bench.sh

# Where to store HPCToolkit measurements
export HPCRUN_OUT=$HOME/hpctoolkit-redis-measurements
export HPCRUN_TMPDIR=$HPCRUN_OUT
rm -rf "$HPCRUN_OUT" && mkdir -p "$HPCRUN_OUT"

# Start redis-server under hpcrun, using the selected TUNA config
hpcrun -o "$HPCRUN_OUT" \
       -e PAPI_L2_TCM@1000 \
       -e PAPI_L3_TCM@1000 \
       -- redis-server $HOME/pcbench/redis/configs/TUNA_best_redis_config.conf --port 6379 --protected-mode no
```

### 4B. In another terminal, **drive the workload** while `hpcrun` is active:

```bash
$YCSB_DIR/bin/ycsb.sh run redis \
  -s -P $YCSB_DIR/workloads/workloada \
  -p recordcount=1800000 \
  -p operationcount=2000000000 \
  -p threadcount=10 \
  -p maxexecutiontime=60 \
  -p redis.host=127.0.0.1 \
  -p redis.port=6379

START_SERVER=0 STOP_SERVER=0 SKIP_LOAD=1 \
REDIS_CONF=$HOME/pcbench/redis/configs/TUNA_best_redis_config.conf \
RECORDCOUNT=1800000 OPERATIONCOUNT=2000000000 \
WARMUP_SECONDS=0 ITERATIONS=1 DURATION=60 THREADS=10 \
bash $HOME/pcbench/redis/redis_bench.sh \
2>&1 | tee ~/redis_profile_run.log
```

### 4C. Stop the server when done:

```bash
redis-cli shutdown nosave 2>/dev/null || true
```

### 4D. Build the performance database for **hpcviewer**:

```bash
# 1) Structural analysis (DWARF) for redis-server binary and measurements
hpcstruct -j 8 $(command -v redis-server)
hpcstruct -j 8 "$HPCRUN_OUT"

# 2) Correlate measurements with sources/binaries
hpcprof -j 8 -S $HOME/redis-server.hpcstruct -o $HOME/hpctoolkit-redis-database "$HPCRUN_OUT"
```

---

## 5. Inspect hotspots in **hpcviewer** and iterate configs

Export your hpctoolkit database and open it locally in **hpcviewer**.
Capture screenshots of top L2/L3-miss call paths (e.g., dict/listpack ops,
AOF I/O paths, defrag, rehash). 

```bash
sudo apt install -y zip unzip
# zip the database for shipping
zip -r hpctoolkit-redis-database.zip hpctoolkit-redis-database
# Copy the db from cloudlab to your local machine
scp -r -p 22 USERNAME@NODE.CLUSTER.cloudlab.us:/users/USERNAME/hpctoolkit-redis-database.zip .
```

Use those images to ask ChatGPT for a
config-level hypothesis (e.g., `hash-max-listpack-*`, `activedefrag`,
AOF rewrite/fsync cadence).

---

## 6. Evaluate the **ORIGINAL (selected) TUNA config**

Use the Redis benchmarking runner (warmup + N runs + summary):

```bash
chmod +x redis_bench.sh

REDIS_CONF=$HOME/pcbench/redis/configs/TUNA_best_redis_config.conf \
RECORDCOUNT=1800000 OPERATIONCOUNT=2000000000 \
WARMUP_SECONDS=30 ITERATIONS=10 DURATION=120 THREADS=10 \
bash $HOME/pcbench/redis/redis_bench.sh \
  2>&1 | tee ~/redis_bench_results.log
```

This script:

* starts `redis-server` with `TUNA_best_redis_config.conf`,
* loads the initial YCSB dataset (recordcount ≈ 1.8 M) into Redis using `ycsb load redis`,
* runs a short warm‑up using YCSB (default 30 s),
* runs **N iterations** of a timed YCSB workload (default 300 s),
* parses the [OVERALL], Throughput(ops/sec) line from YCSB’s output,
* reports **median/mean/stdev** and appends to `~/redis_bench_results.log`.

---

## 7. Evaluate your **OPTIMIZED** config

Save your tweaks as `redis_optimized.conf`, then run the same benchmark:

```bash
REDIS_CONF=$HOME/pcbench/redis/configs/redis_optimized.conf \
RECORDCOUNT=1800000 OPERATIONCOUNT=2000000000 \
WARMUP_SECONDS=30 ITERATIONS=10 DURATION=120 THREADS=10 \
bash $HOME/pcbench/redis/redis_bench.sh \
  2>&1 | tee ~/redis_bench_results.log
```

Compare median ops/sec and variance to the ORIGINAL run.

---

## 8. Tips

* For realistic high throughput, prefer **multiple threads + clients + pipelining**.
* Keep `-fno-omit-frame-pointer` in Redis build flags for callpath fidelity.
* Pinning the server to specific cores and isolating background noise helps
  reduce throughput variance.
