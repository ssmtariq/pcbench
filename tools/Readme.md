Here’s a single, fault-tolerant, orchestration script that:
  * auto-detects SuT (postgresql|nginx|redis),
  * runs one or more workloads,
  * uses perf stat to decide memory-boundedness,
  * confirms across multiple workloads,
  * detects cache-miss overhead,
  * profiles with HPCToolkit (PAPI L2/L3 misses),
  * collects augmentation (calling context, knobs docs, source code),
  * prepares a ChatGPT bundle to get optimized configs,
  * validates optimized configs (TPS/ops/s), and
  * logs a re-evaluable “oracle” JSONL with metrics & significance.

---

# 0) Shared conventions

* **Root dirs (override anytime):**

  * `ARTI_ROOT` (default: `~/pcbench_runs`)
  * `LOG_DIR=$ARTI_ROOT/logs`
  * `BUNDLE_DIR=$ARTI_ROOT/bundle`
  * `HPCRUN_OUT=$ARTI_ROOT/hpctoolkit_measurements`
  * `HPC_DB=$ARTI_ROOT/hpctoolkit_database`
  * `ORACLE=$ARTI_ROOT/oracle.jsonl`

* **Common knobs (all scripts accept):**

  * `SUT=postgresql|nginx|redis`
  * `WORKLOADS=small|large`
  * `ITER=3`
  * `CONF_PATH=/path/to/config` (optional)
  * `THREADS=$(nproc)`
  * `WARMUP_SECONDS=30` (0 to disable)
  * `DURATION=180` (seconds)
  * `THREADCOUNT`/`CONCURRENCY` as relevant per SUT
  * `BENCH_CFG=/path/to/workload-file` (optional for PG; nginx/redis can run without)

All scripts log to `$LOG_DIR` and create machine-readable outputs (CSV/JSON) that later steps use.

---

# 1) `1_bootstrap.sh` — dependencies & basic setup

```bash
# ALL SuTs (standalone):
bash $HOME/pcbench/tools/1_bootstrap.sh all

# PostgreSQL only (standalone):
bash $HOME/pcbench/tools/1_bootstrap.sh postgresql

# Nginx only (standalone):
bash $HOME/pcbench/tools/1_bootstrap.sh nginx

# Redis only (standalone):
bash $HOME/pcbench/tools/1_bootstrap.sh redis
```

**Verify success:** no errors, and `hpcrun -V`, `perf --version`, `jq --version` all work.

---

# 2) `2_perf_events.sh` — snapshot available perf events (Task 2)

```bash
bash $HOME/pcbench/tools/2_perf_events.sh
```

**Verify:** `cat ~/pcbench_runs/perf_events.txt` contains the events you pasted.

---

# 3) `3_run_workload.sh` — run workloads under `perf stat` (Tasks 1, 3, 4, 5)

* **Parameters:**

  * `SUT=postgresql|nginx|redis` (default: `postgresql`)
  * `WORKLOADS=small|large` (default: `small`)
  * `ITER=3`
  * `CONF_PATH` (optional: SUT config file)
  * `BENCH_CFG` (optional: Postgres BenchBase XML)
  * `WARMUP_SECONDS=30` (0 disables warmup)
  * `DURATION=180` (seconds)
  * `THREADCOUNT` (PG terminals / redis YCSB threads; nginx uses `CONCURRENCY`)
  * `CONCURRENCY` (for nginx ab)

```bash
# PostgreSQL (uses pgsql_bench.sh; ITER is controlled inside that script) 
# WARMUP_SECONDS should be either 0 or 1 only for postgresql
SUT=postgresql WORKLOADS=small ITER=1 WARMUP_SECONDS=0 DURATION=60 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/postgresql/configs/original.conf \
bash $HOME/pcbench/tools/3_run_workload.sh

# nginx
SUT=nginx ITER=1 CONCURRENCY=10 DURATION=60 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/nginx/configs/original.conf \
bash $HOME/pcbench/tools/3_run_workload.sh

# redis
SUT=redis ITER=1 DURATION=60 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/redis/configs/original.conf \
bash $HOME/pcbench/tools/3_run_workload.sh
```
**Verify:** new `perf_*_summary.json` files in `~/pcbench_runs/logs/`
**Verify:** new files like `perf_pg_xxx_summary.json` exist. For PG, BenchBase creates result folders; for nginx/redis, check `perf_*_raw.txt`/`_summary.json`.

---

# 4) `4_classify_memory.sh` — classify memory-boundness & confirm (Tasks 3–5)

```bash
bash $HOME/pcbench/tools/4_classify_memory.sh
# Verify: tail -n +1 ~/pcbench_runs/memory_classification.csv
#         test -f ~/pcbench_runs/memory_confirmed.flag && echo "confirmed"
```

**Verify:** `memory_classification.csv` updated; `memory_confirmed.flag` present only if confirmed.

---

# 5) `5_profiler.sh` — HPCToolkit run when memory-bound (Task 6)

```bash
bash $HOME/pcbench/tools/5_profiler.sh
# Verify: ls -R ~/pcbench_runs/hpctoolkit_database
```

**Verify:** `ls -R $HPC_DB` shows HPCToolkit database.

---

# 6) `6_collect_aug.sh` — collect augmentation bundle (Task 7)

```bash
bash $HOME/pcbench/tools/6_collect_aug.sh
# Verify: ls ~/pcbench_runs/bundle ; open prompt_bundle.md
```

**Verify:** `ls $BUNDLE_DIR` shows `hpctoolkit_db.zip`, knobs docs, logs, and `prompt_bundle.md`.

---

# 7) `7_validator.sh` — validate optimized config & record to oracle (Tasks 8–11)

```bash
# PostgreSQL (uses pgsql_bench.sh; ITER is controlled inside that script)
SUT=postgresql WORKLOADS=large ITER=1 WARMUP_SECONDS=30 DURATION=120 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/postgresql/configs/optimized.conf \
bash $HOME/pcbench/tools/7_validator.sh

# nginx
SUT=nginx ITER=1 WARMUP_SECONDS=30 CONCURRENCY=10 DURATION=120 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/nginx/configs/optimized.conf \
bash $HOME/pcbench/tools/7_validator.sh

# redis
SUT=redis ITER=1 WARMUP_SECONDS=30 DURATION=120 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/redis/configs/optimized.conf \
bash $HOME/pcbench/tools/7_validator.sh

# Verify: tail -n1 ~/pcbench_runs/oracle.jsonl
```

**Verify:** `tail -n1 $ORACLE` shows a new JSON line with metrics.

---

# 8) `8_summarizer.sh` — quick status reporter

```bash
bash $HOME/pcbench/tools/8_summarizer.sh
```

**Verify:** human-readable summary prints and paths exist.

---

# 9) `runner.sh` — single entrypoint that calls each step (Task 4)

```bash
# PostgreSQL (uses pgsql_bench.sh; ITER is controlled inside that script)
SUT=postgresql WORKLOADS=small ITER=1 WARMUP_SECONDS=30 DURATION=120 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/postgresql/configs/original.conf \
bash $HOME/pcbench/tools/runner.sh

# nginx
SUT=nginx ITER=1 WARMUP_SECONDS=30 CONCURRENCY=10 DURATION=120 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/nginx/configs/original.conf \
bash $HOME/pcbench/tools/runner.sh

# redis
SUT=redis ITER=1 WARMUP_SECONDS=30 DURATION=120 THREADCOUNT=10 \
CONFIG_FILE=$HOME/pcbench/redis/configs/original.conf \
bash $HOME/pcbench/tools/runner.sh
```

**Verify:** It prints every step; check the paths it reports.

---

## What gets passed between scripts?

* `2_perf_events.sh` → writes `perf_events.txt`
* `3_run_workload.sh` → writes `perf_*_summary.json`
* `4_classify_memory.sh` → writes `memory_classification.csv` + `memory_confirmed.flag`
* `5_profiler.sh` → writes HPCToolkit DB into `$HPC_DB`
* `6_collect_aug.sh` → writes `bundle/` (hpctoolkit\_db.zip, knob docs, logs, prompt)
* `7_validator.sh` → appends a JSON line to `$ORACLE` with TPS & counter metrics
* `8_summarizer.sh` → reports everything

All paths default to `~/pcbench_runs` but are **fully parameterizable**.

---

## How to confirm correctness at each step

* **Bootstrap:** tools’ versions print; no errors returned.
* **Run perf:** each run creates a `perf_..._summary.json`; open and check `instructions`, `cycles`, `cache-misses`.
* **Classification:** CSV line per run; **≥60%** memory-bound → `memory_confirmed.flag` present.
* **HPCToolkit:** `hpctoolkit_database/` exists; `hpcviewer` can open it offline (when you export).
* **Bundle:** `hpctoolkit_db.zip`, knobs, current config, logs, and `prompt_bundle.md` exist.
* **Validate:** `oracle.jsonl` gets a new JSON line; `improvement_pct` computed (baseline left 0.0 unless you pass your own baseline—easy to extend).

---
