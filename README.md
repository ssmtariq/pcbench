# PC Bench

A tool for benchmarking performance-critical applications

This guide provides a complete, end-to-end walkthrough for running PC Bench on a **CloudLab xl170** or a similar bare-metal node. You'll:

1. Deploy **PostgreSQL 16.1**
2. Generate a **TPC-C** workload
3. Collect **cache-miss call-path profiles** using **HPCToolkit + PAPI (via Spack)**
4. Use results to inform new **GUC knob** designs

---

## 1. Reserve and Prepare the Node

```bash
# In the CloudLab UI:
#  • Choose Ubuntu 22.04 (UBUNTU22-64-STD)
#  • Reserve at least one xl170 node
#  • Enable "sudo" for your user
```

### Enable Performance Counters (Per Boot)

```bash
sudo sysctl -w kernel.perf_event_paranoid=-1
sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'
```
**The rest of the setup from Step-1 until Step-3 can be automated by running the script `common_setup.sh` as below:**

```bash
bash $HOME/pcbench/common_setup.sh
```

Without this, Linux restricts access to raw cache-miss events.

---

## 2. Install Dependencies for TUNA

```bash
# Python 3.11 + pip
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3.11 python3.11-venv python3.11-distutils python3-pip

# Java 21
sudo apt install -y openjdk-21-jdk

# Docker CE (latest)
sudo apt remove -y docker docker-engine docker.io containerd runc
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
newgrp docker

# fio, stress-ng, linux-tools
sudo apt install -y fio stress-ng linux-tools-common linux-tools-$(uname -r)

# Miniconda (installed to /mydata/miniconda3)
CONDA_DIR=/mydata/miniconda3
sudo chown -R $USER /mydata
cd /mydata
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda.sh
bash miniconda.sh -b -p ${CONDA_DIR}
echo "export PATH=${CONDA_DIR}/bin:\$PATH" >> ~/.bashrc
source ${CONDA_DIR}/etc/profile.d/conda.sh
conda init bash
cd ~
```

---

## 3. Install HPCToolkit via Spack

```bash
sudo apt update && sudo apt -y install git build-essential cmake gfortran \
     libssl-dev libreadline-dev zlib1g-dev openjdk-21-jdk

git clone https://github.com/spack/spack.git ~/spack
. ~/spack/share/spack/setup-env.sh
echo ". ~/spack/share/spack/setup-env.sh" >> ~/.bashrc
spack external find gcc gfortran cmake
spack external find papi
spack compiler find
spack mirror add binary_mirror https://binaries.spack.io/releases/v0.20
spack buildcache keys --install --trust

# Install HPCToolkit + PAPI (with workarounds if needed)
spack install -j8 hpctoolkit +papi
spack install -j8 hpctoolkit +papi ~xed
spack install -j8 hpctoolkit +papi ^intel-xed@2023.10.11
spack load hpctoolkit
```

---

## 4. Build PostgreSQL 16.1 (with debug symbols)

```bash
wget https://ftp.postgresql.org/pub/source/v16.1/postgresql-16.1.tar.gz
tar xf postgresql-16.1.tar.gz && cd postgresql-16.1
./configure --prefix=$HOME/pg16 \
            --enable-debug CFLAGS="-g -O2 -fno-omit-frame-pointer" \
            --without-icu
make -j8 && make install
export PATH=$HOME/pg16/bin:$PATH
echo 'export PATH=$HOME/pg16/bin:$PATH' >> ~/.bashrc
initdb -D ~/pgdata
cd ~

# Start PostgreSQL and create user database
pg_ctl -D ~/pgdata -l ~/pglog start
psql -d postgres
CREATE DATABASE USERNAME;
\q;

# Verify installation
psql -c "SELECT version();"
pg_ctl -D ~/pgdata stop;
```

---

## 5. Find Best Postgres Configuration and Set it Up

### Find the best pgsql configuration from TUNA samples
```bash
pip install pandas
python pcbench/best_pg_cfg.py
```

### Setup pgsql to use the selected configuration
```bash
# Install jq and parse selected config
sudo apt update && sudo apt -y install jq
cp ~/pgdata/postgresql.conf ~/pgdata/postgresql.conf.bak

jq -r '
  to_entries[] |
  .key as $k |
  .value as $v |
  ($v|type) as $t |
  if   $t == "string" and ($v|test("^(on|off|true|false)$"))
  then "\($k) = \($v)"
  elif $t == "string"
  then "\($k) = '\''\($v)'\''"
  else "\($k) = \($v)"
  end
'  ~/pcbench/postgresql/configs/TUNA_best_pgsql_config.json >> ~/pgdata/postgresql.conf

chmod 600 ~/pgdata/postgresql.conf
postgres -D ~/pgdata -C max_connections > /dev/null \
  && echo "✓ postgresql.conf parses cleanly" \
  || { echo "✗ postgresql.conf still has errors"; exit 1; }
pg_ctl -D ~/pgdata restart
```

---

## 6. Install JDK 23 for BenchBase

```bash
sudo apt-get update
sudo apt-get install -y curl gnupg lsb-release
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | sudo gpg --dearmor -o /usr/share/keyrings/adoptium-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/adoptium-archive-keyring.gpg] \
  https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/adoptium.list

sudo apt-get update
sudo apt-get install -y temurin-23-jdk
sudo update-alternatives --config java
sudo update-alternatives --config javac
java --version
javac --version
```

---

## 7. Clone and Build BenchBase

```bash
git clone --depth 1 https://github.com/cmu-db/benchbase.git
cd benchbase
./mvnw clean package -P postgres -T 1C -DskipTests
cd target
tar xvzf benchbase-postgres.tgz
cd benchbase-postgres
```

---

## 8. Generate and Run TPCC Workloads for xl170

```bash
sudo apt-get update -y
sudo apt-get install -y maven default-jdk xmlstarlet

# Config generation (small and large TPC-C workloads)
SAMPLE_CONFIG=config/postgres/sample_tpcc_config.xml

# Small test
cp "$SAMPLE_CONFIG" config/postgres/xl170_tpcc_small.xml
xmlstarlet ed -L \
  -u '//parameters/url' -v 'jdbc:postgresql://localhost:5432/benchbase?sslmode=disable&ApplicationName=tpcc&reWriteBatchedInserts=true' \
  -u '//parameters/username' -v "${USER}" \
  -u '//parameters/password' -v '' \
  -u '//parameters/isolation' -v 'TRANSACTION_READ_COMMITTED' \
  -u '//parameters/scalefactor' -v '10' \
  -u '//parameters/terminals' -v '2' \
  -u '//parameters/works/work/time' -v '60' \
  config/postgres/xl170_tpcc_small.xml

# Full run
cp "$SAMPLE_CONFIG" config/postgres/xl170_tpcc_large.xml
xmlstarlet ed -L \
  -u '//parameters/url' -v 'jdbc:postgresql://localhost:5432/benchbase?sslmode=disable&ApplicationName=tpcc&reWriteBatchedInserts=true' \
  -u '//parameters/username' -v "${USER}" \
  -u '//parameters/password' -v '' \
  -u '//parameters/isolation' -v 'TRANSACTION_READ_COMMITTED' \
  -u '//parameters/scalefactor' -v '100' \
  -u '//parameters/terminals' -v '40' \
  -u '//parameters/works/work/time' -v '300' \
  config/postgres/xl170_tpcc_large.xml

# Sanity-check
xmlstarlet sel -t -m '//parameters' -v scalefactor -o ' warehouses, ' \
  -v terminals -o ' terminals, work-times = ' -v 'works/work/time' -n \
  config/postgres/xl170_tpcc_small.xml

# Create DB
cd ~
psql -c "DROP DATABASE IF EXISTS benchbase;"
psql -c "CREATE DATABASE benchbase;"

# Symlink for BenchBase config
ln -s benchbase/target/benchbase-postgres/config ~/config

# Create and load small test
/usr/bin/java  -jar benchbase/target/benchbase-postgres/benchbase.jar \
               -b tpcc \
               -c benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_small.xml \
               --create=true --load=true --execute=false

# Execute small test
/usr/bin/java  -jar benchbase/target/benchbase-postgres/benchbase.jar \
               -b tpcc \
               -c benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_small.xml \
               --create=false --load=false --execute=true

# Run large test
/usr/bin/java  -jar benchbase/target/benchbase-postgres/benchbase.jar \
               -b tpcc \
               -c benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_large.xml \
               --create=false --load=false --execute=true
```

---

## 9. Collect cache‑miss profiles with HPCToolkit

### Wrap the *server* in `hpcrun`

```bash
pg_ctl -D ~/pgdata stop              # Stop any running PostgreSQL instance

# Set HPCToolkit output directory (where measurements will be stored)
export HPCRUN_OUT=$HOME/hpctoolkit-postgres-measurements  

# Set tmpdir to the same path to avoid HPCToolkit writing temp data under pgdata
export HPCRUN_TMPDIR=$HPCRUN_OUT  

# Wrap PostgreSQL startup in hpcrun to collect cache-miss events
hpcrun -o $HPCRUN_OUT             \
       -e PAPI_L2_TCM@1000        \
       -e PAPI_L3_TCM@1000        \
       -- pg_ctl -D ~/pgdata -l ~/pglog start
```

*What the options mean*

| Flag                     | Why                                                                                                                          |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `-e PAPI_L3_TCM@1000000` | Sample once every 1 M LLC (L3) misses – a good starting frequency.                                                           |
| `PAPI_L2_TCM`            | Also sample unified L2 misses to see if thrashing starts earlier.                                                            |
| `-dd CPU`                | Tells hpcrun to follow **all** forked Postgres back‑end processes.                                                           |
| `hpcrun … -- <cmd>`      | Runs Postgres with the sampling library preloaded. HPCToolkit uses PAPI underneath for hardware counters.([hpc.llnl.gov][5]) |

### Drive the workload *while hpcrun is active*

```bash
# Run small workload
/usr/bin/java  -jar benchbase/target/benchbase-postgres/benchbase.jar \
               -b tpcc \
               -c benchbase/target/benchbase-postgres/config/postgres/xl170_tpcc_small.xml \
               --create=false --load=false --execute=true
```

### Stop the server when done:

```bash
pg_ctl -D ~/pgdata stop;
```

---

## 10. Build the performance database

```bash
# 1. Structural analysis (DWARF + CFG)
hpcstruct -j 8 $HOME/pg16/bin/postgres
hpcstruct -j 8 $HPCRUN_OUT

# 2. Correlate measurements with source & binaries
hpcprof  -j 8  \
         -S $HOME/postgres.hpcstruct \
         -o $HOME/hpctoolkit-pg-database $HPCRUN_OUT
```

---

## 11. Inspect results

### Ship the hpctoolkit database to your local machine and use hpcviewer for inspection

   ```bash
    sudo apt install -y zip unzip
    # zip the database for shipping
    zip -r hpctoolkit-pg-database-benchbase.zip hpctoolkit-pg-database
    # Copy the db from cloudlab to your local machine
    scp -r -p 22 USERNAME@NODE.CLUSTER.cloudlab.us:/users/USERNAME/hpctoolkit-pg-database-benchbase.zip .
   ```
---

## 12.  From hotspots to new GUC knobs (example workflow)

1. **Identify culprit code.**
   Suppose 40 % of L3 misses sit in `BufferAlloc()` while reading shared buffers.

2. **Hypothesise a tunable.**
   If misses spike when the freelist is exhausted, add a knob `prefetch_buffer_batch` controlling how many pages `BufferAlloc()` pre‑fetches.

3. **Add the knob to Postgres.**

```diff
--- a/src/backend/utils/misc/guc_tables.c
+++ b/src/backend/utils/misc/guc_tables.c
@@
+    {
+        {"prefetch_buffer_batch", PGC_POSTMASTER, RESOURCES_MEM,
+         gettext_noop("Pages to prefetch into shared buffers in one batch."),
+         NULL, GUC_NOT_IN_SAMPLE
+        },
+        &prefetch_buffer_batch,
+        8, 1, 1024
+    },
```

* Declare `int prefetch_buffer_batch;` in `src/include/utils/guc_variables.h`.
* Rebuild Postgres, restart, and **re‑profile** to validate.

4. **Iterate.**
   Rinse‑and‑repeat with other high‑miss regions (e.g., `hash_search_with_hash_value`, WAL insert paths).

---

## 13. Why each technology?

| Tool                          | Role                                                                                                                                                         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **HPCToolkit**                | Low‑overhead *statistical* profiler that records full calling context across every Postgres back‑end – perfect for multi‑process servers.([hpc.llnl.gov][5]) |
| **PAPI**                      | Uniform access to raw hardware counters (`PAPI_L3_TCM`, `PAPI_L2_TCM`, …) across Intel/AMD CPUs; HPCToolkit links to it automatically.([icl.utk.edu][7])     |
| **Spack**                     | One‑command build of HPCToolkit + PAPI from source with all needed libraries – avoids manual patching.([HPCToolkit][2])                                      |
| **tpcc‑postgres / HammerDB**  | Generates a realistic OLTP workload (TPC‑C) to stress Postgres and expose cache contention.([GitHub][4])                                                     |
| **hpcviewer / hpcviewer‑cli** | Interactive or web‑based GUI where you correlate cache‑miss metrics with source lines and loops, then export tables/graphs for reports.([HPCToolkit][6])     |

---

### At a glance

1. **Allocate node → disable perf restrictions**
2. **Spack install hpctoolkit + papi**
3. **Build Postgres with `-g -fno-omit-frame-pointer`**
4. **Wrap server in `hpcrun` (cache‑miss events)**
5. **Run TPC‑C workload**
6. **`hpcstruct` → `hpcprof` → `hpcviewer`**
7. **Spot hotspots → design & add new GUCs**
8. **Re‑tune, re‑profile, iterate**

Follow this loop and you’ll have data‑driven evidence—down to the exact source lines—for any new configuration knobs that meaningfully reduce cache misses and raise TPC‑C throughput on PostgreSQL 16.1. Good luck, and happy tuning!

