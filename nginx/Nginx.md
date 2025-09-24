# Nginx Cache Profiling and Tuning with TUNA on CloudLab xl170

This guide walks you through reproducing the TUNA workflow for
**nginx‐1.27** on a CloudLab **xl170** node. You will build nginx from
source with debug symbols, select a high‑performing configuration from
TUNA's sample runs, profile the server with **HPCToolkit** and **PAPI**,
and then iteratively optimize and re‑evaluate the configuration using
the provided benchmarking script. The overall approach mirrors the
PC Bench PostgreSQL example but targets an HTTP server instead of a
database.

## 1. Build nginx 1.27 with debug symbols

To profile nginx effectively you need debug information and frame
pointers. Nginx is configured and built using the `configure` command
followed by `make` and
`make install`[\[1\]](https://nginx.org/en/docs/configure.html#:~:text=Building%20nginx%20from%20Sources);
the `--with-debug` option enables the debugging
log[\[2\]](https://nginx.org/en/docs/configure.html#:~:text=%60). We
also pass `CFLAGS="-g -O2 -fno-omit-frame-pointer"` so that HPCToolkit
can unwind call stacks correctly.
```bash
# Fetch and unpack nginx (adjust version if a newer 1.27.x release is available)
wget http://nginx.org/download/nginx-1.27.0.tar.gz
tar xf nginx-1.27.0.tar.gz && cd nginx-1.27.0

# Configure with debug support and frame pointers
export CFLAGS="-g -O2 -fno-omit-frame-pointer"
./configure \
    --prefix=$HOME/nginx \
    --with-http_ssl_module \
    --with-threads \
    --with-file-aio \
    --with-debug

# Build and install
make -j8
make install
cd ~

# Add nginx to your PATH
echo 'export PATH=$HOME/nginx/sbin:$PATH' >> ~/.bashrc
source ~/.bashrc

#Try nginx
nginx 
#If port binding fails at 80 then update the nginx.conf file "listen" to unprevileged port e.g. 8080
code ~/nginx/conf/nginx.conf
nginx -s stop
# Copy the configs from pcbench/nginx/configs/* to ~/nginx/conf/
```

At this point `nginx -V` should report version 1.27.0 with the
`--with-debug` flag enabled and your binaries will include symbols.

## 2. Clone TUNA and pick the best nginx configuration

To automatically select the best nginx configuration from the TUNA **Azure
wikipedia** workload, run the provided Python script:
```bash
pip install pandas
python3 best_nginx_config_finder.py
```
The script clones TUNA into a temporary directory (if not already
present), scans all `TUNA_run*.csv` files under
`sample_configs/azure/nginx/wikipedia`, filters the high‑fidelity rows
(those with the maximum `Worker` value per run) and chooses the row with
the highest **Performance** metric. It writes the selected knob values
to `TUNA_best_nginx_config.json` and prints the corresponding worker
count, performance and source file.

## 3. Convert JSON config file into an nginx configuration

The JSON file `TUNA_best_nginx_config.json` contains key--value pairs for nginx's tunable knobs.
We need to create a new configuration file (e.g. `~/nginx/conf/original.conf`)
starting from the default `nginx.conf`. Inside the `http` block add one
directive per key from the JSON. For example, a JSON entry
```bash
{
    "sendfile": "on",
    "tcp_nopush": "on",
    "open_file_cache": "inactive=60s max=5000"
}
```
becomes
```bash
http {
    ... # existing directives
    sendfile on;
    tcp_nopush on;
    open_file_cache inactive=60s max=5000;
    ...
}
```
Make sure to place the directives in the appropriate context (`http` or
`server`) and comment out any conflicting defaults. 
Run the script to do it automatically:
```bash
sh $HOME/pcbench/nginx/configbuilder.sh
```
Then test the syntax:
```bash
nginx -t -c ~/nginx/conf/original.conf
```

## 4. Benchmark the selected configuration

Install the **wrk** tool if it is not already present. The following
commands build wrk from source:
```bash
git clone https://github.com/wg/wrk.git ~/wrk
cd ~/wrk
make -j8
```
Use the `nginx_bench.sh` script to evaluate throughput. By
default it runs 10 iterations of 30 seconds each with 4 threads and 64
concurrent connections. It starts nginx with your config, drives traffic
using wrk, parses the `Requests/sec` value and finally computes
mean/median throughput and standard deviation. Example:
```bash
NGINX_CONF=$HOME/nginx/conf/original.conf \
WARMUP_SECONDS=0 ITERATIONS=1 DURATION=30 THREADS=10 CONNECTIONS=10 \
bash $HOME/pcbench/nginx/nginx_bench.sh
```
The script logs per‑run results in a temporary directory and appends a
summary entry to `$HOME/nginx_bench_results.log` for easy tracking.

## 5. Profile nginx with HPCToolkit

### 5A With the best configuration applied, collect cache‑miss profiles to identify hot spots. 
HPCToolkit uses PAPI events (L2 and L3 cache misses)
to sample call stacks.

```bash
# 1. Stop any running nginx instance
nginx -s stop
# 2. Set HPCToolkit output directory (where measurements will be stored)
export HPCRUN_OUT=$HOME/hpctoolkit-nginx-measurements
export HPCRUN_TMPDIR=$HPCRUN_OUT
rm -rf "$HPCRUN_OUT" && mkdir -p "$HPCRUN_OUT"
```
### 5B **Launch nginx wrapped under** `hpctoolkit`. 
    Use two events: `PAPI_L2_TCM` and `PAPI_L3_TCM` with a sampling period of 1000 misses each. 
    The `--` separates hpcrun options from the command being profiled.

```bash
# load hpctoolkit in the terminal
spack load hpctoolkit
export NGINX_BIN="$HOME/nginx/sbin/nginx"
export NGINX_CONF="$HOME/nginx/conf/original.conf"

# 3. Wrap nginx startup in hpcrun to collect cache-miss events
hpcrun  -o "$HPCRUN_OUT" \
        -e PAPI_L2_TCM@1000 \
        -e PAPI_L3_TCM@1000 \
        -- $NGINX_BIN -c $NGINX_CONF -p "$(dirname "$(dirname "$NGINX_CONF")")"
```
### 5C **Drive the workload** while hpcrun is recording. 
```bash
# 4. Profile nginx
"$HOME/wrk/wrk" -t 10 -c 10 -d 60s --latency http://localhost:8080/
# 5. Stop nginx after the workload completes
nginx -s stop
```

### 5D **Create the performance database**. 
    HPCToolkit needs both structural information (DWARF and control‑flow graphs) 
    and measurement data. Generate these as follows:

```bash
# 6. Structural analysis (DWARF + CFG)
hpcstruct -j8 $NGINX_BIN
hpcstruct -j8 "$HPCRUN_OUT"
# 7. Correlate measurements with source & binaries
hpcprof  -j8 \
            -S $HOME/nginx.hpcstruct \
            -o $HOME/hpctoolkit-nginx-database "$HPCRUN_OUT"
```
### 5E **Inspect with hpcviewer**. 
    Transfer the `hpctoolkit-nginx-database` directory to your workstation 
    and open it in the HPC Viewer GUI.
    Sort the call‑path table by `PAPI_L3_TCM` to find the worst cache
    offenders. Export tables or flame graphs as PNG images and feed them
    into ChatGPT for qualitative analysis.

```bash
sudo apt install -y zip unzip
# zip the database for shipping
zip -r hpctoolkit-nginx-database.zip hpctoolkit-nginx-database
# Copy the db from cloudlab to your local machine
scp -r -p 22 USERNAME@NODE.CLUSTER.cloudlab.us:/users/USERNAME/hpctoolkit-nginx-database.zip .
```

## 6. Refine the configuration using ChatGPT's feedback

After inspecting the HPCToolkit profiles you might notice that
particular functions or modules suffer from heavy cache misses. For
instance, high miss rates in the upstream proxy module might hint that
`sendfile` should be enabled or that `open_file_cache` needs adjusting.
Present the exported images to ChatGPT and ask for suggestions on which
nginx knobs could improve cache locality. Apply the recommended changes
to a new configuration file (e.g. `optimized.conf`).

## 7. Re‑evaluate the orignal and optimized configuration

Repeat the benchmarking step with your optimized configuration:
```bash
#Run original config
NGINX_CONF=$HOME/nginx/conf/original.conf \
WARMUP_SECONDS=30 ITERATIONS=10 DURATION=120 THREADS=10 CONNECTIONS=10 \
bash $HOME/pcbench/nginx/nginx_bench.sh

#Test optimized config
nginx -t -c ~/nginx/conf/optimized.conf
# Run optimized config
NGINX_CONF=$HOME/nginx/conf/optimized.conf \
WARMUP_SECONDS=30 ITERATIONS=10 DURATION=120 THREADS=10 CONNECTIONS=10 \
bash $HOME/pcbench/nginx/nginx_bench.sh
```
Compare the mean and median throughputs against those of the original
configuration. If performance improves and cache misses decrease, commit
the new configuration. Otherwise iterate: profile again, analyse the
call paths, refine the knobs and measure. This data‑driven loop is
exactly what TUNA advocates.
