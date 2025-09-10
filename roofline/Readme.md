Here’s a clean, repeatable way to put **PostgreSQL-16.1 + BenchBase** on a **LIKWID Roofline**, including **L1/L2/L3** and **memory bandwidth**, on a **CloudLab xl170 (Ubuntu 22.04)**. I’m re-using your existing BenchBase runner (`pgsql_bench.sh`) and the setup you already documented.

---

# Step-by-step (what you’ll do)

1. **Make sure PG + BenchBase are ready (from your README):**

   * Build and initialize PostgreSQL-16.1, add it to `PATH`, and create `~/pgdata`.&#x20;
   * (Optional) Apply your best config and restart Postgres.&#x20;
   * Install JDK and build BenchBase. &#x20;
   * Generate the xl170 TPCC configs; note the JDBC URL already sets `ApplicationName=tpcc` (we use this to find the backend PID automatically). &#x20;
   * Create the `benchbase` database (if needed) and sanity-run TPCC once. &#x20;

2. **Install LIKWID** (and xmlstarlet if missing):

   ```bash
   sudo apt-get update
   sudo apt-get install -y likwid xmlstarlet
   ```

3. **Lower perf restrictions** (per-boot or for this session):

   ```bash
   echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null
   # (Your README shows using -1 as well; either works on a bare-metal xl170.) :contentReference[oaicite:8]{index=8}
   ```

4. **Run the orchestrator script below.** It will:

   * Measure **roof bandwidths** for **L1/L2/L3/Memory** using `likwid-bench`.
   * Launch **your `pgsql_bench.sh`** (warmup optional) for one measured run.
   * Automatically find a **PostgreSQL backend PID** serving BenchBase (`application_name='tpcc'`).
   * **Pin** that backend to a chosen core(s).
   * Attach **LIKWID** to that PID and record **MEM**, **L3**, **L2**, **L1** bandwidth and **CPI/Instructions**, then compute **Instruction/Byte intensity** (DB-friendly Roofline).
   * Emit a **summary CSV** + full logs in a timestamped results dir.

---

---

# How to run (copy-paste)

1. **Make the script executable:**

```bash
chmod +x $HOME/pcbench/roofline/likwid_roofline_pgsql.sh
chmod +x ~/pcbench/postgresql/pgsql_bench.sh
```

2. **Make sure BenchBase configs exist and DB is created** (your README’s TPCC steps).&#x20;

## Enable MSR access (one-off per boot)
```bash
# Load the msr driver
sudo modprobe msr

# Loosen perf restrictions (your README suggests -1 on bare metal)
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null

# (Simplest for experiments) allow MSR read/write for this session
sudo chmod a+rw /dev/cpu/*/msr

# Now verify groups show up:
likwid-perfctr -a | sed 's/^[[:space:]]*//' | egrep '^(MEM|CPI|L1|L2|L3|L1CACHE|L2CACHE|L3CACHE)'
export LIKWID_PERF_GROUPS=/usr/share/likwid/perfgroups
```

3. **Run a Small (60s) TPCC with warmup and measure Roofline:**

```bash
WARMUP=1 WORKLOAD=small ITERATIONS=1 CORES=2 \
bash $HOME/pcbench/roofline/likwid_roofline_pgsql.sh
```

* `CORES=2` pins the measured Postgres backend to core 2 (adjust to your reserved cores).
* The script will **find the backend PID automatically** by `application_name='tpcc'` (present in your configs).&#x20;

4. **Run a Large (300s) TPCC:**

```bash
WARMUP=1 WORKLOAD=large ITERATIONS=1 CORES=2-3 THREADS=10 \
bash $HOME/pcbench/roofline/likwid_roofline_pgsql.sh
```

* Here we pin to two cores and also use two threads for the roof measurements.

5. **Inspect outputs:**

* Results live under: `~/likwid_roofline/<timestamp>/`
* **`roofline_summary.csv`** gives you:

  * `app_*_bandwidth` (MBytes/s) for MEM/L3/L2/L1 (app point)
  * `app_instr_per_byte` (Instruction Roofline intensity)
  * `roof_*` (L1/L2/L3/MEM peaks from `likwid-bench`)
* Full raw outputs are in `roofs/*.out` and `app/*.out` for auditing.

6. **Generate roofline plot:**
```bash
pip install matplotlib
python3 $HOME/pcbench/roofline/plot_roofline.py ~/likwid_roofline/<timestamp>/roofline_summary.csv roofline.png
```
---

## Notes & why this matches your setup

* We rely on your existing **`pgsql_bench.sh`** to load data, restart PG, and run the measured execute (and it already prints clean TPS summaries and logs).  &#x20;
* Your README already covers **how you built PG 16.1** and **how you generated the xl170 TPCC configs** (including `ApplicationName=tpcc`, which lets us auto-find the backend). &#x20;
* If you prefer HPCToolkit call-path views, your README shows wrapping PG in `hpcrun` with L2/L3 miss events; use that separately for deep code-level analysis, while LIKWID gives you the **Roofline point**. &#x20;

---

## What you get

* **Multiple roofs** (L1/L2/L3/MEM) from `likwid-bench`.
* **One app point** (DB backend) with:

  * **Memory bandwidth** (MBytes/s) and cache-level bandwidths (when the group exists on your CPU).
  * **Instructions/s** and **Instruction/Byte intensity** (DB-friendly Roofline).
* A **fault-tolerant**, step-by-step log and a **summary CSV** you can drop into a plotting script later.

