#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# nginx-build-best-conf.sh
# Convert TUNA_best_nginx_config.json -> nginx_best.conf by merging into
# the base nginx.conf, commenting conflicting defaults, and testing syntax.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# --- paths (adjust if your prefix differs) -----------------------------------
NGINX_PREFIX="${NGINX_PREFIX:-$HOME/nginx}"
CONF_IN="${CONF_IN:-$NGINX_PREFIX/conf/nginx.conf}"
CONF_OUT="${CONF_OUT:-$NGINX_PREFIX/conf/nginx_best.conf}"
JSON_IN="${JSON_IN:-$HOME/pcbench/nginx/configs/TUNA_best_nginx_config.json}"

# 0) sanity checks + backup
echo "Step 0: Sanity checks"
echo "  • Base nginx.conf           : $CONF_IN"
echo "  • JSON config (input)       : $JSON_IN"
[[ -f "$CONF_IN" ]] || { echo "  ✗ Missing $CONF_IN"; exit 1; }
[[ -f "$JSON_IN" ]] || { echo "  ✗ Missing $JSON_IN"; exit 1; }

BACKUP="${CONF_IN}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$CONF_IN" "$BACKUP"
echo "  ✓ Created backup of nginx.conf at: $BACKUP"

# 1) generate nginx_best.conf by merging JSON knobs into the default config
echo "Step 1: Build $CONF_OUT from $CONF_IN + $JSON_IN"
export NGINX_PREFIX CONF_IN CONF_OUT JSON_IN
python3 - <<'PY'
import json, os, re, pathlib

prefix   = os.environ.get("NGINX_PREFIX", os.path.expanduser("~/nginx"))
conf_in  = os.environ["CONF_IN"]
conf_out = os.environ["CONF_OUT"]
json_in  = os.environ["JSON_IN"]

print(f"  1.1 Reading JSON knobs from: {json_in}")
with open(json_in, "r") as fh:
    raw = json.load(fh)

def normalize(d):
    out = {"http": {}, "server": {}}
    for k, v in d.items():
        if k in ("http","server") and isinstance(v, dict):
            out[k].update(v)
        else:
            out["http"][k] = v
    return out

knobs = normalize(raw)
print(f"  1.2 Normalized contexts: http={len(knobs['http'])} directives, server={len(knobs['server'])} directives")

print(f"  1.3 Reading base config from: {conf_in}")
with open(conf_in, "r") as fh:
    lines = fh.readlines()

def find_block(lines, name):
    open_pat  = re.compile(r'^\s*' + re.escape(name) + r'\s*\{')
    brace = 0
    start = None
    for i, line in enumerate(lines):
        if start is None:
            if open_pat.search(line):
                start = i
                brace = line.count('{') - line.count('}')
        else:
            brace += line.count('{') - line.count('}')
            if brace == 0:
                return start, i
    return None, None

http_start, http_end = find_block(lines, "http")
server_start, server_end = find_block(lines, "server")

def comment_conflicts(block_slice, directives):
    dir_names = set(directives.keys())
    def is_match(line, name):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            return False
        return re.match(r'^' + re.escape(name) + r'\b', stripped) is not None
    conflicts = 0
    for i, line in enumerate(block_slice):
        for name in dir_names:
            if is_match(line, name):
                block_slice[i] = "# TUNA override: " + line
                conflicts += 1
                break
    return conflicts

def directives_to_lines(directives):
    out = []
    for k, v in directives.items():
        if v is None or (isinstance(v, str) and v.strip() == ""):
            out.append(f"    {k};\n")
        else:
            out.append(f"    {k} {v};\n")
    return out

def inject_into_block(lines, start, end, directives, label):
    created_block = False
    if start is None or end is None:
        if label == "http":
            lines.append("\nhttp {\n}\n")
            # re-locate newly added block
            s2, e2 = find_block(lines, "http")
            created_block = True
            start, end = s2, e2
        else:
            print(f"  1.5 Skipping injection into missing '{label}' block (0 directives applied).")
            return lines, 0, 0, created_block
    sub = lines[start:end+1]
    conflicts = comment_conflicts(sub, directives)
    annotated = ["    # --- TUNA best config overrides begin ---\n", *directives_to_lines(directives), "    # --- TUNA best config overrides end ---\n"]
    new_block = sub[:-1] + annotated + [sub[-1]]
    lines[start:end+1] = new_block
    return lines, len(directives), conflicts, created_block

if knobs["http"]:
    lines, applied_http, conflicts_http, created_http = inject_into_block(lines, http_start, http_end, knobs["http"], "http")
    if created_http:
        print(f"  1.4 Created missing 'http' block and injected {applied_http} directive(s); commented {conflicts_http} conflicting default(s).")
    else:
        print(f"  1.4 Injected {applied_http} 'http' directive(s); commented {conflicts_http} conflicting default(s).")
else:
    print("  1.4 No 'http' directives specified; nothing to inject.")

if knobs["server"]:
    lines, applied_srv, conflicts_srv, created_srv = inject_into_block(lines, server_start, server_end, knobs["server"], "server")
    if applied_srv:
        print(f"  1.5 Injected {applied_srv} 'server' directive(s); commented {conflicts_srv} conflicting default(s).")
else:
    print("  1.5 No 'server' directives specified; nothing to inject.")

pathlib.Path(conf_out).parent.mkdir(parents=True, exist_ok=True)
with open(conf_out, "w") as fh:
    fh.writelines(lines)
print(f"  1.6 Wrote final config to: {conf_out}")
PY

# 1.7 Ensure an unprivileged listen port (default: 8080) to avoid bind errors as non-root
NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-8080}"
# Replace IPv4/IPv6 'listen 80' with the chosen port; keep other flags (e.g., default_server)
sed -i.bak -E "s/^[[:space:]]*listen[[:space:]]+80(\b[^;]*;)/listen ${NGINX_LISTEN_PORT}\1/" "$CONF_OUT" || true
sed -i     -E "s/^[[:space:]]*listen[[:space:]]+\[::\]:80(\b[^;]*;)/listen [::]:${NGINX_LISTEN_PORT}\1/" "$CONF_OUT" || true
echo "  1.7 Ensured server listens on port ${NGINX_LISTEN_PORT} (non-root friendly)"

# 2) test the generated configuration
echo "Step 2: Test syntax of generated config"
echo "  • Running: $NGINX_PREFIX/sbin/nginx -t -c $CONF_OUT"
"$NGINX_PREFIX/sbin/nginx" -t -c "$CONF_OUT"

echo "Done."
echo "Summary:"
echo "  • JSON (input)          : $(readlink -f "$JSON_IN" 2>/dev/null || echo "$JSON_IN")"
echo "  • Final config (output) : $(readlink -f "$CONF_OUT" 2>/dev/null || echo "$CONF_OUT")"
echo "  • Backup of nginx.conf  : $(readlink -f "$BACKUP" 2>/dev/null || echo "$BACKUP")"
