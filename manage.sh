#!/usr/bin/env bash
# ==============================================================================
# AI Stack Manager (9Router + Hermes Agent + Caddy + Xray)
# Version: 2.0.0
# License: MIT
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Global Constants & Paths
# ------------------------------------------------------------------------------
VERSION="2.0.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

if [[ "$(id -u)" -eq 0 ]]; then
    DEFAULT_STACK_DIR="/opt/ai-stack"
else
    DEFAULT_STACK_DIR="${HOME}/ai-stack"
fi
STACK_DIR="${STACK_DIR:-$DEFAULT_STACK_DIR}"
LOCK_FILE="/tmp/ai-stack.lock"
LOCK_FD=200

# Color and formatting
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_MAGENTA="\033[35m"
    C_CYAN="\033[36m"
    C_WHITE="\033[37m"
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
    C_WHITE=""
fi

# ------------------------------------------------------------------------------
# Logging Helpers
# ------------------------------------------------------------------------------
log()     { printf "%b\n" "$*"; }
info()    { printf "%b[INFO]%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
success() { printf "%b[OK]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf "%b[ERROR]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Mutual Exclusion (Flock)
# ------------------------------------------------------------------------------
acquire_lock() {
    local non_blocking="${1:-false}"
    eval "exec $LOCK_FD>\"$LOCK_FILE\""
    if [[ "$non_blocking" == "true" ]]; then
        if ! flock -n "$LOCK_FD"; then
            die "Another instance of $SCRIPT_NAME is currently running."
        fi
    else
        info "Waiting for stack lock..."
        flock "$LOCK_FD"
    fi
}

release_lock() {
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec $LOCK_FD>&-" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

cleanup() {
    local exit_code=$?
    release_lock
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Path & Directory Initialization
# ------------------------------------------------------------------------------
init_paths() {
    mkdir -p "$STACK_DIR"/{certs,backups,state,Caddyfile.d,xray,hermes}
    chmod 700 "$STACK_DIR" 2>/dev/null || true
    chmod 700 "$STACK_DIR/certs" "$STACK_DIR/backups" 2>/dev/null || true
    
    # Touch state files if missing
    touch "$STACK_DIR/.env"
    touch "$STACK_DIR/domains.tsv"
    touch "$STACK_DIR/Caddyfile.d/custom"
    
    # Ensure hermes data dir has appropriate ownership (UID 10000 for hermes)
    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R 10000:10000 "$STACK_DIR/hermes" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Safe .env Key/Value Management (Zero eval, strict escaping)
# ------------------------------------------------------------------------------
# Read a value from .env without sourcing or eval
env_get() {
    local key="$1"
    local default_val="${2:-}"
    local env_file="$STACK_DIR/.env"
    
    if [[ ! -f "$env_file" ]]; then
        printf "%s\n" "$default_val"
        return 0
    fi
    
    local val
    val=$(python3 - "$key" "$env_file" "$default_val" << 'PYEOF'
import sys, re
key = sys.argv[1]
pattern = re.compile(r'^\s*' + re.escape(key) + r'\s*=\s*(.*)$')
found = None
try:
    with open(sys.argv[2], 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            m = pattern.match(line)
            if m:
                raw = m.group(1).strip()
                if raw.startswith("'") and raw.endswith("'"):
                    found = raw[1:-1].replace(r"'\''", "'")
                elif raw.startswith('"') and raw.endswith('"'):
                    found = raw[1:-1].replace(r'\"', '"').replace(r'\\', '\\')
                else:
                    found = raw
except Exception:
    pass
if found is not None:
    print(found)
else:
    print(sys.argv[3])
PYEOF
)
    printf "%s\n" "$val"
}

# Set a value in .env safely with single-quote escaping
env_set() {
    local key="$1"
    local val="$2"
    local env_file="$STACK_DIR/.env"
    
    init_paths
    
    python3 - "$key" "$val" "$env_file" << 'PYEOF'
import sys, re
key, val, path = sys.argv[1], sys.argv[2], sys.argv[3]
escaped_val = val.replace("'", r"'\''")
entry = f"{key}='{escaped_val}'\n"

lines = []
found = False
pattern = re.compile(r'^\s*' + re.escape(key) + r'\s*=.*$')

try:
    with open(path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
except FileNotFoundError:
    pass

new_lines = []
for line in lines:
    if pattern.match(line):
        if not found:
            new_lines.append(entry)
            found = True
    else:
        new_lines.append(line)

if not found:
    if new_lines and not new_lines[-1].endswith('\n'):
        new_lines.append('\n')
    new_lines.append(entry)

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)
PYEOF
    chmod 600 "$env_file" 2>/dev/null || true
}

# Generate cryptographically secure random token
generate_secret() {
    local length="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$length" 2>/dev/null || true
    else
        head -c "$length" /dev/urandom | od -A n -v -t x1 | tr -d ' \n'
    fi
}

# Ensure all mandatory secrets are present in .env
ensure_stack_secrets() {
    init_paths
    local need_save=0
    
    local secrets=(
        "JWT_SECRET:32"
        "API_KEY_SECRET:32"
        "MACHINE_ID_SALT:16"
        "HERMES_DASHBOARD_BASIC_AUTH_SECRET:32"
        "API_SERVER_KEY:32"
    )
    
    for item in "${secrets[@]}"; do
        local key="${item%%:*}"
        local len="${item##*:}"
        local cur
        cur=$(env_get "$key" "")
        if [[ -z "$cur" ]]; then
            local gen
            gen=$(generate_secret "$len")
            env_set "$key" "$gen"
            need_save=1
        fi
    done
    
    # Defaults for other critical 9Router / Hermes options
    if [[ -z "$(env_get "REQUIRE_API_KEY" "")" ]]; then
        env_set "REQUIRE_API_KEY" "false"
    fi
    if [[ -z "$(env_get "AUTH_COOKIE_SECURE" "")" ]]; then
        env_set "AUTH_COOKIE_SECURE" "true"
    fi
    if [[ -z "$(env_get "STACK_PROFILE" "")" ]]; then
        env_set "STACK_PROFILE" "auto"
    fi
    if [[ -z "$(env_get "PROXY_ENABLED" "")" ]]; then
        env_set "PROXY_ENABLED" "false"
    fi
    if [[ -z "$(env_get "PROXY_MODE" "")" ]]; then
        env_set "PROXY_MODE" "none"
    fi
    if [[ -z "$(env_get "HERMES_DASHBOARD_ENABLED" "")" ]]; then
        env_set "HERMES_DASHBOARD_ENABLED" "true"
    fi
    if [[ -z "$(env_get "HERMES_API_ENABLED" "")" ]]; then
        env_set "HERMES_API_ENABLED" "true"
    fi
    if [[ -z "$(env_get "CADDY_ENABLED" "")" ]]; then
        env_set "CADDY_ENABLED" "auto"
    fi
    if [[ -z "$(env_get "NINE_ROUTER_MAX_MEM" "")" ]]; then
        env_set "NINE_ROUTER_MAX_MEM" "256"
    fi
}

# ------------------------------------------------------------------------------
# Hermes config.yaml Merge Helper
# ------------------------------------------------------------------------------
# Merges model and dashboard sections without clobbering existing configuration
merge_hermes_config() {
    local config_file="$STACK_DIR/hermes/config.yaml"
    local model_name="$1"
    local nine_router_key="$2"
    local dashboard_domain="${3:-localhost}"
    
    init_paths
    
    python3 -c "
import sys, os, re

config_file = sys.argv[1]
model_name = sys.argv[2]
api_key = sys.argv[3]
domain = sys.argv[4]

content = ''
if os.path.isfile(config_file):
    with open(config_file, 'r', encoding='utf-8') as f:
        content = f.read()

# Replace or append top-level blocks safely
def replace_or_append_block(text, block_name, new_block_content):
    pattern = re.compile(r'(?m)^' + re.escape(block_name) + r':(?:\n(?:\s+.*|\s*))*')
    if pattern.search(text):
        return pattern.sub(new_block_content.strip(), text, count=1)
    else:
        trimmed = text.rstrip()
        prefix = (trimmed + '\n\n') if trimmed else ''
        return prefix + new_block_content.strip() + '\n'

new_model_block = f'''model:
  default: {model_name}
  provider: custom
  base_url: http://nine-router:20128/v1
  api_key: {api_key}'''

public_url = f'https://{domain}' if domain != 'localhost' else 'http://localhost:9119'

new_dashboard_block = f'''dashboard:
  public_url: {public_url}
  trusted_proxies:
    - 127.0.0.1/32
    - 172.16.0.0/12
    - 10.0.0.0/8'''

content = replace_or_append_block(content, 'model', new_model_block)
content = replace_or_append_block(content, 'dashboard', new_dashboard_block)

# Clean trailing whitespace/excess newlines
content = re.sub(r'\n{3,}', '\n\n', content).strip() + '\n'

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(content)
" "$config_file" "$model_name" "$nine_router_key" "$dashboard_domain"

    # Set permissions so container UID 10000 can read and write
    chmod 666 "$config_file" 2>/dev/null || true
    if [[ "$(id -u)" -eq 0 ]]; then
        chown 10000:10000 "$config_file" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Proxy & Xray Subsystem
# ------------------------------------------------------------------------------

# Parse share link into Xray outbound JSON object (Python helper)
xray_parse_link() {
    local link="$1"
    local tag="$2"
    
    python3 -c "
import sys, json, base64, urllib.parse

link = sys.argv[1].strip()
tag = sys.argv[2].strip()

try:
    if link.startswith('vless://'):
        u = urllib.parse.urlparse(link)
        params = urllib.parse.parse_qs(u.query)
        stream_settings = {'network': params.get('type', ['tcp'])[0]}
        sec = params.get('security', ['none'])[0]
        stream_settings['security'] = sec
        if sec == 'reality':
            stream_settings['realitySettings'] = {
                'show': False,
                'serverName': params.get('sni', [''])[0],
                'publicKey': params.get('pbk', [''])[0],
                'shortId': params.get('sid', [''])[0],
                'spiderX': params.get('spx', [''])[0]
            }
        elif sec == 'tls':
            stream_settings['tlsSettings'] = {
                'serverName': params.get('sni', [''])[0],
                'allowInsecure': params.get('allowInsecure', ['false'])[0].lower() in ['1', 'true']
            }
        
        flow = params.get('flow', [''])[0]
        vnext = [{
            'address': u.hostname,
            'port': u.port or 443,
            'users': [{'id': u.username, 'encryption': params.get('encryption', ['none'])[0], 'flow': flow}]
        }]
        outbound = {
            'tag': tag,
            'protocol': 'vless',
            'settings': {'vnext': vnext},
            'streamSettings': stream_settings
        }
        print(json.dumps(outbound))

    elif link.startswith('trojan://'):
        u = urllib.parse.urlparse(link)
        params = urllib.parse.parse_qs(u.query)
        stream_settings = {
            'network': params.get('type', ['tcp'])[0],
            'security': params.get('security', ['tls'])[0],
            'tlsSettings': {'serverName': params.get('sni', [''])[0]}
        }
        outbound = {
            'tag': tag,
            'protocol': 'trojan',
            'settings': {
                'servers': [{
                    'address': u.hostname,
                    'port': u.port or 443,
                    'password': u.username
                }]
            },
            'streamSettings': stream_settings
        }
        print(json.dumps(outbound))

    elif link.startswith('vmess://'):
        b64 = link[8:]
        pad = len(b64) % 4
        if pad:
            b64 += '=' * (4 - pad)
        data = json.loads(base64.b64decode(b64).decode('utf-8'))
        stream_settings = {
            'network': data.get('net', 'tcp'),
            'security': data.get('tls', 'none')
        }
        if data.get('tls') == 'tls':
            stream_settings['tlsSettings'] = {'serverName': data.get('sni', '')}
        outbound = {
            'tag': tag,
            'protocol': 'vmess',
            'settings': {
                'vnext': [{
                    'address': data.get('add'),
                    'port': int(data.get('port', 443)),
                    'users': [{'id': data.get('id'), 'alterId': int(data.get('aid', 0)), 'security': 'auto'}]
                }]
            },
            'streamSettings': stream_settings
        }
        print(json.dumps(outbound))

    elif link.startswith('ss://'):
        # Format ss://BASE64@host:port or ss://BASE64#tag
        raw = link[5:]
        userinfo, _, hostport = raw.partition('@')
        if not hostport:
            b64, _, hash_tag = raw.partition('#')
            pad = len(b64) % 4
            if pad:
                b64 += '=' * (4 - pad)
            decoded = base64.b64decode(b64).decode('utf-8')
            userinfo, _, hostport = decoded.partition('@')
        else:
            pad = len(userinfo) % 4
            if pad:
                userinfo += '=' * (4 - pad)
            userinfo = base64.b64decode(userinfo).decode('utf-8')
            
        method, _, password = userinfo.partition(':')
        host, _, port_part = hostport.partition(':')
        port = int(port_part.split('#')[0].split('/')[0])
        
        outbound = {
            'tag': tag,
            'protocol': 'shadowsocks',
            'settings': {
                'servers': [{
                    'address': host,
                    'port': port,
                    'method': method,
                    'password': password
                }]
            }
        }
        print(json.dumps(outbound))
    else:
        sys.exit(1)
except Exception as e:
    sys.exit(1)
" "$link" "$tag"
}

# Generate full Xray config.json from links.txt
xray_generate_config() {
    init_paths
    local links_file="$STACK_DIR/xray/links.txt"
    local config_file="$STACK_DIR/xray/config.json"
    
    if [[ ! -f "$links_file" ]] || [[ ! -s "$links_file" ]]; then
        return 0
    fi
    
    python3 -c "
import sys, os, json, subprocess

links_file = sys.argv[1]
config_file = sys.argv[2]
script_path = sys.argv[3]

outbounds = []
tags = []

idx = 1
with open(links_file, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        tag = f'node-{idx}'
        res = subprocess.run([script_path, 'xray-parse-internal', line, tag], capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip():
            try:
                ob = json.loads(res.stdout.strip())
                outbounds.append(ob)
                tags.append(tag)
                idx += 1
            except Exception:
                pass

if not outbounds:
    sys.exit(0)

# Add fallback direct and block outbounds
outbounds.append({'tag': 'direct', 'protocol': 'freedom', 'settings': {}})
outbounds.append({'tag': 'block', 'protocol': 'blackhole', 'settings': {}})

config = {
    'log': {'loglevel': 'warning'},
    'inbounds': [
        {
            'tag': 'socks-in',
            'port': 10808,
            'listen': '0.0.0.0',
            'protocol': 'socks',
            'settings': {'auth': 'noauth', 'udp': True},
            'sniffing': {
                'enabled': True,
                'destOverride': ['http', 'tls'],
                'routeOnly': True
            }
        },
        {
            'tag': 'http-in',
            'port': 10809,
            'listen': '0.0.0.0',
            'protocol': 'http',
            'settings': {'allowTransparent': False},
            'sniffing': {
                'enabled': True,
                'destOverride': ['http', 'tls'],
                'routeOnly': True
            }
        }
    ],
    'outbounds': outbounds,
    'routing': {
        'domainStrategy': 'AsIs',
        'balancers': [
            {
                'tag': 'balancer',
                'selector': tags,
                'strategy': {'type': 'leastPing'}
            }
        ],
        'rules': [
            {
                'type': 'field',
                'domain': ['geosite:private', 'geosite:ir', 'domain:ir'],
                'outboundTag': 'direct'
            },
            {
                'type': 'field',
                'ip': ['geoip:ir', '127.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
                'outboundTag': 'direct'
            },
            {
                'type': 'field',
                'network': 'tcp,udp',
                'balancerTag': 'balancer'
            }
        ]
    },
    'observatory': {
        'subjectSelector': tags,
        'probeUrl': 'https://api.openai.com',
        'probeInterval': '1m'
    }
}

with open(config_file, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2)
" "$links_file" "$config_file" "$SCRIPT_PATH"
    chmod 644 "$config_file" 2>/dev/null || true
}

# Return active proxy URL usable from the host OS when proxy is enabled
get_active_host_proxy() {
    local enabled
    enabled=$(env_get "PROXY_ENABLED" "false")
    [[ "$enabled" != "true" ]] && return 0
    
    local mode
    mode=$(env_get "PROXY_MODE" "none")
    if [[ "$mode" == "external" ]]; then
        env_get "PROXY_URL" ""
    elif [[ "$mode" == "xray" ]]; then
        printf "http://127.0.0.1:10809\n"
    fi
}

# Wrapper for curl that automatically routes through the stack proxy when enabled
outbound_curl() {
    local proxy_url
    proxy_url=$(get_active_host_proxy)
    if [[ -n "$proxy_url" ]]; then
        curl --proxy "$proxy_url" "$@"
    else
        curl "$@"
    fi
}

# Print exportable proxy environment variables for host shell usage
proxy_env() {
    local proxy_url
    proxy_url=$(get_active_host_proxy)
    if [[ -z "$proxy_url" ]]; then
        warn "Proxy is not currently enabled."
        return 1
    fi
    local socks_url="$proxy_url"
    if [[ "$(env_get "PROXY_MODE" "none")" == "xray" ]]; then
        socks_url="socks5h://127.0.0.1:10808"
    fi
    cat << EOF
export HTTP_PROXY="${proxy_url}"
export HTTPS_PROXY="${proxy_url}"
export ALL_PROXY="${socks_url}"
export http_proxy="${proxy_url}"
export https_proxy="${proxy_url}"
export all_proxy="${socks_url}"
export NO_PROXY="localhost,127.0.0.1,172.16.0.0/12,192.168.0.0/16,.ir"
export no_proxy="localhost,127.0.0.1,172.16.0.0/12,192.168.0.0/16,.ir"
EOF
}

# Execute any host command routed through the active stack proxy
proxy_exec() {
    if [[ $# -eq 0 ]]; then
        die "Usage: $SCRIPT_NAME proxy exec <command> [args...]"
    fi
    local proxy_url
    proxy_url=$(get_active_host_proxy)
    if [[ -z "$proxy_url" ]]; then
        die "Proxy is not enabled. Enable it first with '$SCRIPT_NAME proxy add-link' or 'set-external'."
    fi
    local socks_url="$proxy_url"
    if [[ "$(env_get "PROXY_MODE" "none")" == "xray" ]]; then
        socks_url="socks5h://127.0.0.1:10808"
    fi
    HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url" ALL_PROXY="$socks_url" \
    http_proxy="$proxy_url" https_proxy="$proxy_url" all_proxy="$socks_url" \
    NODE_USE_ENV_PROXY=1 \
    "$@"
}

# Proxy status output
proxy_status() {
    local enabled
    enabled=$(env_get "PROXY_ENABLED" "false")
    local mode
    mode=$(env_get "PROXY_MODE" "none")
    local ext_url
    ext_url=$(env_get "PROXY_URL" "")
    
    printf "%bProxy Configuration:%b\n" "$C_BOLD" "$C_RESET"
    printf "  Enabled: %s\n" "$([[ "$enabled" == "true" ]] && printf "%bYes%b" "$C_GREEN" "$C_RESET" || printf "%bNo%b" "$C_DIM" "$C_RESET")"
    printf "  Mode:    %s\n" "$mode"
    
    if [[ "$mode" == "external" ]]; then
        printf "  URL:     %s\n" "$ext_url"
    elif [[ "$mode" == "xray" ]]; then
        local links_count=0
        if [[ -f "$STACK_DIR/xray/links.txt" ]]; then
            links_count=$(grep -cve '^\s*$' "$STACK_DIR/xray/links.txt" 2>/dev/null || true)
        fi
        printf "  Nodes:   %s links imported\n" "$links_count"
        printf "  Stack:   socks5h://xray:10808, http://xray:10809\n"
        printf "  Host:    socks5h://127.0.0.1:10808, http://127.0.0.1:10809\n"
    fi
}

proxy_set_external() {
    local url="${1:-}"
    if [[ -z "$url" ]]; then
        read -r -p "Enter proxy URL (e.g. socks5://127.0.0.1:1080 or http://10.0.0.1:8080): " url
    fi
    if [[ -z "$url" ]]; then
        warn "No proxy URL provided."
        return 1
    fi
    env_set "PROXY_URL" "$url"
    env_set "PROXY_MODE" "external"
    env_set "PROXY_ENABLED" "true"
    generate_docker_compose
    success "Configured external proxy: $url"
}

proxy_add_link() {
    local link="${1:-}"
    if [[ -z "$link" ]]; then
        read -r -p "Paste share link (vless://, vmess://, trojan://, ss://): " link
    fi
    link=$(printf "%s" "$link" | tr -d '\r\n ')
    if [[ -z "$link" ]]; then
        warn "Empty link."
        return 1
    fi
    
    local parsed
    parsed=$(xray_parse_link "$link" "test-node" || true)
    if [[ -z "$parsed" ]]; then
        err "Invalid or unsupported share link."
        return 1
    fi
    
    init_paths
    printf "%s\n" "$link" >> "$STACK_DIR/xray/links.txt"
    xray_generate_config
    env_set "PROXY_MODE" "xray"
    env_set "PROXY_ENABLED" "true"
    generate_docker_compose
    success "Added node and re-generated Xray balancer configuration."
}

proxy_clear_links() {
    init_paths
    rm -f "$STACK_DIR/xray/links.txt" "$STACK_DIR/xray/config.json"
    touch "$STACK_DIR/xray/links.txt"
    if [[ "$(env_get "PROXY_MODE" "")" == "xray" ]]; then
        env_set "PROXY_MODE" "none"
        env_set "PROXY_ENABLED" "false"
    fi
    generate_docker_compose
    success "Cleared all Xray links."
}

proxy_enable() {
    local mode
    mode=$(env_get "PROXY_MODE" "none")
    if [[ "$mode" == "none" ]]; then
        warn "No proxy mode configured. Set external URL or add Xray link first."
        return 1
    fi
    env_set "PROXY_ENABLED" "true"
    generate_docker_compose
    success "Proxy enabled ($mode mode)."
}

proxy_disable() {
    env_set "PROXY_ENABLED" "false"
    generate_docker_compose
    success "Proxy disabled."
}

# ------------------------------------------------------------------------------
# Iran Resilience & Network Subsystem
# ------------------------------------------------------------------------------

# Detect if current host is located in Iran or behind Iranian network restrictions
detect_iran_network() {
    local profile
    profile=$(env_get "STACK_PROFILE" "auto")
    if [[ "$profile" == "iran" ]]; then
        return 0
    elif [[ "$profile" == "intl" ]]; then
        return 1
    fi
    
    # Check IP geolocation
    local country=""
    country=$(curl -s --max-time 3 https://api.country.is/ 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get("country", ""))' 2>/dev/null || true)
    if [[ "$country" == "IR" ]]; then
        return 0
    fi
    
    # Check for DNS poisoning (10.10.34.x redirect)
    local poisoned=0
    local test_ips
    test_ips=$(python3 -c "
import socket
try:
    infos = socket.getaddrinfo('twitter.com', 80)
    for info in infos:
        ip = info[4][0]
        if ip.startswith('10.10.34.'):
            print('poisoned')
            break
except Exception:
    pass
" 2>/dev/null || true)
    if [[ "$test_ips" == "poisoned" ]]; then
        return 0
    fi
    
    # Check direct connectivity to Docker Hub
    if ! curl -s --connect-timeout 2 -I https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Test responsiveness of a Docker registry mirror
test_docker_mirror() {
    local mirror="$1"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "$mirror/v2/" 2>/dev/null || true)
    if [[ "$code" == "200" ]] || [[ "$code" == "401" ]]; then
        return 0
    fi
    return 1
}

# Configure Docker registry mirrors in /etc/docker/daemon.json
configure_docker_mirrors() {
    if [[ "$(id -u)" -ne 0 ]]; then
        warn "Root privileges required to configure Docker daemon mirrors."
        return 1
    fi
    
    info "Testing available Iranian Docker registry mirrors..."
    local candidate_mirrors=(
        "https://docker.arvancloud.ir"
        "https://docker.iranserver.com"
        "https://registry.docker.ir"
        "https://docker.mwt.me"
    )
    local working=()
    
    for m in "${candidate_mirrors[@]}"; do
        if test_docker_mirror "$m"; then
            info "  Mirror active: $m"
            working+=("$m")
        else
            warn "  Mirror unreachable: $m"
        fi
    done
    
    if [[ ${#working[@]} -eq 0 ]]; then
        warn "No responsive mirrors found. Keeping existing Docker configuration."
        return 1
    fi
    
    mkdir -p /etc/docker
    local daemon_json="/etc/docker/daemon.json"
    
    # Backup existing
    if [[ -f "$daemon_json" ]]; then
        cp "$daemon_json" "${daemon_json}.bak.$(date +%s)"
    fi
    
    python3 -c "
import sys, json, os

path = sys.argv[1]
mirrors = sys.argv[2:]

data = {}
if os.path.exists(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        data = {}

data['registry-mirrors'] = mirrors

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
" "$daemon_json" "${working[@]}"
    
    info "Restarting Docker daemon to apply mirrors..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
    success "Docker mirrors configured successfully."
}

# Configure Docker MTU if network experiences packet fragmentation
configure_docker_mtu() {
    local mtu="${1:-1400}"
    if [[ "$(id -u)" -ne 0 ]]; then
        warn "Root privileges required to configure MTU."
        return 1
    fi
    
    local daemon_json="/etc/docker/daemon.json"
    mkdir -p /etc/docker
    if [[ -f "$daemon_json" ]]; then
        cp "$daemon_json" "${daemon_json}.bak.$(date +%s)"
    fi
    
    python3 -c "
import sys, json, os

path = sys.argv[1]
mtu = int(sys.argv[2])

data = {}
if os.path.exists(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        data = {}

data['mtu'] = mtu

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
" "$daemon_json" "$mtu"

    systemctl daemon-reload 2>/dev/null || true
    systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
    success "Docker MTU set to $mtu."
}

# Fallback docker installation for Iran VPSs
install_docker_fallback() {
    info "Attempting Docker installation..."
    if command -v docker >/dev/null 2>&1; then
        success "Docker is already installed."
        return 0
    fi
    
    if [[ "$(id -u)" -ne 0 ]]; then
        die "Root permissions required to install Docker."
    fi
    
    info "Trying official get.docker.com script..."
    if outbound_curl -fsSL --connect-timeout 10 https://get.docker.com | bash; then
        success "Docker installed via get.docker.com"
        return 0
    fi
    
    warn "Official script failed or timed out. Falling back to distribution packages..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y docker.io docker-compose-plugin || apt-get install -y docker.io docker-compose
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y docker-ce docker-compose-plugin || dnf install -y docker
    elif command -v yum >/dev/null 2>&1; then
        yum install -y docker
    else
        die "Unsupported package manager. Please install Docker manually."
    fi
    
    systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true
    success "Docker installed via system package manager."
}

# Export container images into an offline bundle
bundle_export() {
    local target="${1:-$STACK_DIR/backups/ai-stack-bundle-$(date +%Y%m%d_%H%M%S).tar.gz}"
    init_paths
    info "Exporting stack images to $target..."
    
    local images=(
        "decolua/9router:latest"
        "nousresearch/hermes-agent:latest"
        "caddy:2-alpine"
        "teddysun/xray:latest"
    )
    
    docker save "${images[@]}" | gzip > "$target"
    success "Export complete: $(du -h "$target" | cut -f1)"
}

# Import container images from an offline bundle
bundle_import() {
    local file="${1:-}"
    if [[ -z "$file" ]] || [[ ! -f "$file" ]]; then
        die "Usage: $SCRIPT_NAME bundle import <bundle_file.tar.gz>"
    fi
    
    info "Importing container images from $file..."
    gzip -dc "$file" | docker load
    success "Bundle import completed."
}

# ------------------------------------------------------------------------------
# Domain & Caddy Subsystem
# ------------------------------------------------------------------------------

# Check if an IP belongs to Cloudflare or ArvanCloud CDN CIDRs
check_cdn_provider() {
    local domain="$1"
    python3 -c "
import sys, socket, ipaddress

domain = sys.argv[1].strip()
cf_cidrs = [
    '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22',
    '141.101.64.0/18', '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20',
    '197.234.240.0/22', '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13',
    '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22'
]
arvan_cidrs = [
    '185.143.232.0/22', '94.182.182.0/24', '188.229.116.0/24', '109.201.210.0/24',
    '212.16.76.0/24', '178.22.122.0/24', '185.143.235.0/24', '185.231.115.0/24'
]

cf_nets = [ipaddress.ip_network(c) for c in cf_cidrs]
arvan_nets = [ipaddress.ip_network(c) for c in arvan_cidrs]

provider = 'Direct / Unknown'
try:
    infos = socket.getaddrinfo(domain, 80)
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        for net in cf_nets:
            if ip in net:
                provider = 'Cloudflare'
                break
        for net in arvan_nets:
            if ip in net:
                provider = 'ArvanCloud'
                break
except Exception:
    provider = 'Unresolvable'

print(provider)
" "$domain"
}

# Generate Caddyfile from domains.tsv
generate_caddyfile() {
    init_paths
    local caddyfile="$STACK_DIR/Caddyfile"
    local domains_tsv="$STACK_DIR/domains.tsv"
    local acme_email
    acme_email=$(env_get "ACME_EMAIL" "")
    local disable_http3
    disable_http3=$(env_get "DISABLE_HTTP3" "false")
    
    python3 -c "
import sys, os

caddyfile = sys.argv[1]
domains_tsv = sys.argv[2]
email = sys.argv[3].strip()
disable_http3 = sys.argv[4].strip().lower() == 'true'

lines = []
# Global configuration block
lines.append('{')
if email:
    lines.append(f'    email {email}')
if disable_http3:
    lines.append('    servers {')
    lines.append('        protocols h1 h2')
    lines.append('    }')
lines.append('}')
lines.append('')

has_domains = False
if os.path.exists(domains_tsv):
    with open(domains_tsv, 'r', encoding='utf-8') as f:
        for row in f:
            row = row.strip()
            if not row or row.startswith('#'):
                continue
            parts = row.split('\t')
            if len(parts) < 3:
                continue
            has_domains = True
            domain, service, tls_mode = parts[0], parts[1], parts[2]
            cert = parts[3] if len(parts) > 3 else ''
            key = parts[4] if len(parts) > 4 else ''
            
            lines.append(f'{domain} {{')
            
            # TLS mode
            if tls_mode == 'internal':
                lines.append('    tls internal')
            elif tls_mode == 'origin' and cert and key:
                lines.append(f'    tls /etc/caddy/certs/{domain}/cert.pem /etc/caddy/certs/{domain}/key.pem')
            elif tls_mode == 'auto':
                # Automatic Let'\''s Encrypt with ZeroSSL fallback
                lines.append('    tls {')
                lines.append('        issuer zerossl')
                lines.append('        issuer acme')
                lines.append('    }')
                
            # Service routing
            if service == '9router':
                lines.append('    reverse_proxy nine-router:20128')
            elif service == 'hermes':
                lines.append('    reverse_proxy hermes:9119')
            elif service == 'both':
                lines.append('    handle /api/v1/* {')
                lines.append('        reverse_proxy nine-router:20128')
                lines.append('    }')
                lines.append('    handle /v1/* {')
                lines.append('        reverse_proxy nine-router:20128')
                lines.append('    }')
                lines.append('    handle {')
                lines.append('        reverse_proxy hermes:9119')
                lines.append('    }')
            lines.append('}')
            lines.append('')

if not has_domains:
    # Default fallback block for port 80/443 when no domain configured yet
    lines.append(':80 {')
    lines.append('    respond \"AI Stack is running. Add a domain using: manage.sh domain add\" 200')
    lines.append('}')
    lines.append('')

lines.append('import /etc/caddy/Caddyfile.d/*')

with open(caddyfile, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
" "$caddyfile" "$domains_tsv" "$acme_email" "$disable_http3"
    chmod 644 "$caddyfile" 2>/dev/null || true
}

# Reload Caddy gracefully without dropping traffic
caddy_reload() {
    if ! docker compose -f "$STACK_DIR/docker-compose.yml" ps --services --filter "status=running" 2>/dev/null | grep -q "^caddy$"; then
        return 0
    fi
    
    info "Validating Caddyfile configuration..."
    if docker compose -f "$STACK_DIR/docker-compose.yml" exec -T caddy caddy validate --config /etc/caddy/Caddyfile; then
        info "Reloading Caddy..."
        docker compose -f "$STACK_DIR/docker-compose.yml" exec -T caddy caddy reload --config /etc/caddy/Caddyfile
        success "Caddy reloaded successfully."
    else
        err "Caddyfile validation failed! Changes not applied."
        return 1
    fi
}

# List configured domains
domain_list() {
    init_paths
    local domains_tsv="$STACK_DIR/domains.tsv"
    
    printf "\n%bConfigured Domains:%b\n" "$C_BOLD" "$C_RESET"
    printf "%-30s %-12s %-10s %-15s\n" "DOMAIN" "SERVICE" "TLS" "CDN PROVIDER"
    printf "%-30s %-12s %-10s %-15s\n" "------------------------------" "------------" "----------" "---------------"
    
    local count=0
    while IFS=$'\t' read -r dom srv tls cert key || [[ -n "$dom" ]]; do
        [[ -z "$dom" || "$dom" =~ ^# ]] && continue
        local cdn
        cdn=$(check_cdn_provider "$dom")
        printf "%-30s %-12s %-10s %-15s\n" "$dom" "$srv" "$tls" "$cdn"
        ((count++)) || true
    done < "$domains_tsv"
    
    if [[ $count -eq 0 ]]; then
        printf "%b(No domains configured yet)%b\n" "$C_DIM" "$C_RESET"
    fi
    printf "\n"
}

# Add a domain
domain_add() {
    init_paths
    local domain="${1:-}"
    local service="${2:-}"
    local tls_mode="${3:-}"
    
    if [[ -z "$domain" ]]; then
        read -r -p "Domain name (e.g. ai.example.com): " domain
    fi
    domain=$(printf "%s" "$domain" | tr '[:upper:]' '[:lower:]' | tr -d ' /')
    
    if [[ -z "$domain" ]]; then
        die "Domain name cannot be empty."
    fi
    
    # Check if domain already exists
    if grep -q "^${domain}[[:space:]]" "$STACK_DIR/domains.tsv" 2>/dev/null; then
        die "Domain $domain is already configured."
    fi
    
    # Inspect CDN
    local cdn
    cdn=$(check_cdn_provider "$domain")
    info "Detected DNS/CDN provider: $cdn"
    
    if [[ -z "$service" ]]; then
        printf "\nSelect service to expose on %s:\n" "$domain"
        printf "  1) 9Router (OpenAI-compatible AI Proxy)\n"
        printf "  2) Hermes Agent (Dashboard & API)\n"
        printf "  3) Both (Routes /v1 and /api to 9Router, root to Hermes)\n"
        read -r -p "Choice [1-3] (default 1): " s_choice
        case "${s_choice:-1}" in
            2) service="hermes" ;;
            3) service="both" ;;
            *) service="9router" ;;
        esac
    fi
    
    if [[ -z "$tls_mode" ]]; then
        printf "\nSelect TLS Mode:\n"
        printf "  1) Auto (Let's Encrypt / ZeroSSL DV ACME)\n"
        printf "  2) Origin Certificate (Cloudflare / ArvanCloud full SSL)\n"
        printf "  3) Internal (Self-signed / local / Tailscale)\n"
        if [[ "$cdn" == "Cloudflare" ]] || [[ "$cdn" == "ArvanCloud" ]]; then
            info "Note: CDN detected. Origin Certificate (2) is recommended."
        fi
        read -r -p "Choice [1-3] (default 1): " t_choice
        case "${t_choice:-1}" in
            2) tls_mode="origin" ;;
            3) tls_mode="internal" ;;
            *) tls_mode="auto" ;;
        esac
    fi
    
    local cert_file=""
    local key_file=""
    if [[ "$tls_mode" == "origin" ]]; then
        local cert_dir="$STACK_DIR/certs/$domain"
        mkdir -p "$cert_dir"
        chmod 700 "$cert_dir"
        cert_file="$cert_dir/cert.pem"
        key_file="$cert_dir/key.pem"
        
        printf "\nPaste Origin Certificate for %s (end with empty line or Ctrl+D):\n" "$domain"
        local cert_content=""
        while IFS= read -r line; do
            [[ -z "$line" && "$cert_content" =~ -----END[[:space:]]CERTIFICATE----- ]] && break
            cert_content+="$line"$'\n'
        done
        printf "%s" "$cert_content" > "$cert_file"
        
        printf "\nPaste Origin Private Key for %s:\n" "$domain"
        local key_content=""
        while IFS= read -r line; do
            [[ -z "$line" && "$key_content" =~ -----END[[:space:]]PRIVATE[[:space:]]KEY----- ]] && break
            key_content+="$line"$'\n'
        done
        printf "%s" "$key_content" > "$key_file"
        chmod 600 "$key_file"
    fi
    
    printf "%s\t%s\t%s\t%s\t%s\n" "$domain" "$service" "$tls_mode" "$cert_file" "$key_file" >> "$STACK_DIR/domains.tsv"
    generate_caddyfile
    
    # If hermes is exposed, update hermes config dashboard domain
    if [[ "$service" == "hermes" || "$service" == "both" ]]; then
        local current_model
        current_model=$(env_get "DEFAULT_MODEL" "nousresearch/hermes-3-llama-3.1-8b")
        local current_key
        current_key=$(env_get "INITIAL_PASSWORD" "123456")
        merge_hermes_config "$current_model" "$current_key" "$domain"
    fi
    
    generate_docker_compose
    if ! docker compose -f "$STACK_DIR/docker-compose.yml" ps --services --filter "status=running" 2>/dev/null | grep -q "^caddy$"; then
        if docker compose -f "$STACK_DIR/docker-compose.yml" ps --services --filter "status=running" 2>/dev/null | grep -q "^nine-router$"; then
            info "Starting Caddy reverse proxy for newly added domain..."
            docker compose -f "$STACK_DIR/docker-compose.yml" up -d caddy
        fi
    else
        caddy_reload
    fi
    success "Domain $domain configured successfully."
}

# Remove a domain
domain_rm() {
    init_paths
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        domain_list
        read -r -p "Enter domain to remove: " domain
    fi
    domain=$(printf "%s" "$domain" | tr '[:upper:]' '[:lower:]' | tr -d ' /')
    
    if ! grep -q "^${domain}[[:space:]]" "$STACK_DIR/domains.tsv" 2>/dev/null; then
        warn "Domain $domain not found."
        return 1
    fi
    
    sed -i "/^${domain}[[:space:]]/d" "$STACK_DIR/domains.tsv"
    rm -rf "$STACK_DIR/certs/$domain"
    generate_caddyfile
    caddy_reload
    success "Domain $domain removed."
}

# ------------------------------------------------------------------------------
# Optional Features & Lightweight Mode Subsystem
# ------------------------------------------------------------------------------

features_status() {
    init_paths
    ensure_stack_secrets
    local dash_en
    dash_en=$(env_get "HERMES_DASHBOARD_ENABLED" "true")
    local api_en
    api_en=$(env_get "HERMES_API_ENABLED" "true")
    local caddy_en
    caddy_en=$(env_get "CADDY_ENABLED" "auto")
    local router_mem
    router_mem=$(env_get "NINE_ROUTER_MAX_MEM" "256")
    
    printf "%bOptional Features & Resource Limits:%b\n" "$C_BOLD" "$C_RESET"
    printf "  Hermes Web UI (Port 9119):  %s\n" "$([[ "$dash_en" == "true" ]] && printf "%bEnabled%b" "$C_GREEN" "$C_RESET" || printf "%bDisabled (Lightweight)%b" "$C_YELLOW" "$C_RESET")"
    printf "  Hermes API (Port 8642):     %s\n" "$([[ "$api_en" == "true" ]] && printf "%bEnabled%b" "$C_GREEN" "$C_RESET" || printf "%bDisabled (Lightweight)%b" "$C_YELLOW" "$C_RESET")"
    printf "  Caddy Reverse Proxy:        %s\n" "$caddy_en (auto = runs only when domains exist)"
    printf "  9Router V8 Heap Cap:        %s MB\n" "$router_mem"
}

features_set() {
    init_paths
    local feature="${1:-}"
    local val="${2:-}"
    
    case "$feature" in
        dashboard)
            case "$val" in
                on|true|1)  env_set "HERMES_DASHBOARD_ENABLED" "true"; success "Hermes Web UI enabled." ;;
                off|false|0) env_set "HERMES_DASHBOARD_ENABLED" "false"; success "Hermes Web UI disabled (lightweight mode)." ;;
                *) die "Usage: $SCRIPT_NAME features dashboard <on|off>" ;;
            esac
            ;;
        api)
            case "$val" in
                on|true|1)  env_set "HERMES_API_ENABLED" "true"; success "Hermes API server enabled." ;;
                off|false|0) env_set "HERMES_API_ENABLED" "false"; success "Hermes API server disabled (lightweight mode)." ;;
                *) die "Usage: $SCRIPT_NAME features api <on|off>" ;;
            esac
            ;;
        caddy)
            case "$val" in
                auto)        env_set "CADDY_ENABLED" "auto"; success "Caddy set to auto (runs only when domains are configured)." ;;
                on|true|1)   env_set "CADDY_ENABLED" "true"; success "Caddy forced on." ;;
                off|false|0) env_set "CADDY_ENABLED" "false"; success "Caddy disabled." ;;
                *) die "Usage: $SCRIPT_NAME features caddy <auto|on|off>" ;;
            esac
            ;;
        memory)
            if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 128 ]]; then
                env_set "NINE_ROUTER_MAX_MEM" "$val"
                success "9Router max V8 memory limit set to ${val}MB."
            else
                die "Usage: $SCRIPT_NAME features memory <megabytes> (min: 128)"
            fi
            ;;
        *)
            die "Usage: $SCRIPT_NAME features <status|dashboard|api|caddy|memory> [value]"
            ;;
    esac
    generate_docker_compose
}

# ------------------------------------------------------------------------------
# Docker Compose Subsystem
# ------------------------------------------------------------------------------

generate_docker_compose() {
    init_paths
    ensure_stack_secrets
    
    local compose_file="$STACK_DIR/docker-compose.yml"
    local proxy_enabled
    proxy_enabled=$(env_get "PROXY_ENABLED" "false")
    local proxy_mode
    proxy_mode=$(env_get "PROXY_MODE" "none")
    local proxy_url
    proxy_url=$(env_get "PROXY_URL" "")
    
    local jwt_secret
    jwt_secret=$(env_get "JWT_SECRET")
    local api_key_secret
    api_key_secret=$(env_get "API_KEY_SECRET")
    local machine_id_salt
    machine_id_salt=$(env_get "MACHINE_ID_SALT")
    local initial_password
    initial_password=$(env_get "INITIAL_PASSWORD" "123456")
    local require_api_key
    require_api_key=$(env_get "REQUIRE_API_KEY" "false")
    local auth_cookie_secure
    auth_cookie_secure=$(env_get "AUTH_COOKIE_SECURE" "true")
    
    local hermes_user
    hermes_user=$(env_get "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "admin")
    local hermes_pass
    hermes_pass=$(env_get "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" "admin123")
    local hermes_secret
    hermes_secret=$(env_get "HERMES_DASHBOARD_BASIC_AUTH_SECRET")
    local api_server_key
    api_server_key=$(env_get "API_SERVER_KEY")
    
    local dash_enabled
    dash_enabled=$(env_get "HERMES_DASHBOARD_ENABLED" "true")
    local api_enabled
    api_enabled=$(env_get "HERMES_API_ENABLED" "true")
    local caddy_enabled
    caddy_enabled=$(env_get "CADDY_ENABLED" "auto")
    local router_max_mem
    router_max_mem=$(env_get "NINE_ROUTER_MAX_MEM" "256")
    
    python3 -c "
import sys, os

out = sys.argv[1]
proxy_enabled = sys.argv[2] == 'true'
proxy_mode = sys.argv[3]
proxy_url = sys.argv[4]

jwt_secret = sys.argv[5]
api_key_secret = sys.argv[6]
machine_id_salt = sys.argv[7]
initial_password = sys.argv[8]
require_api_key = sys.argv[9]
auth_cookie_secure = sys.argv[10]

hermes_user = sys.argv[11]
hermes_pass = sys.argv[12]
hermes_secret = sys.argv[13]
api_server_key = sys.argv[14]
stack_dir = sys.argv[15]

dash_enabled = sys.argv[16] == 'true'
api_enabled = sys.argv[17] == 'true'
caddy_mode = sys.argv[18]
router_max_mem = sys.argv[19]

http_proxy_val = ''
socks_proxy_val = ''
if proxy_enabled:
    if proxy_mode == 'xray':
        http_proxy_val = 'http://xray:10809'
        socks_proxy_val = 'socks5h://xray:10808'
    elif proxy_mode == 'external' and proxy_url:
        http_proxy_val = proxy_url
        socks_proxy_val = proxy_url

proxy_env_block = ''
if http_proxy_val:
    proxy_env_block = f'''      - HTTP_PROXY={http_proxy_val}
      - HTTPS_PROXY={http_proxy_val}
      - ALL_PROXY={socks_proxy_val}
      - http_proxy={http_proxy_val}
      - https_proxy={http_proxy_val}
      - all_proxy={socks_proxy_val}
      - NODE_USE_ENV_PROXY=1
      - GLOBAL_AGENT_HTTP_PROXY={http_proxy_val}
      - NO_PROXY=localhost,127.0.0.1,nine-router,hermes,caddy,xray,172.16.0.0/12,192.168.0.0/16,.ir
      - no_proxy=localhost,127.0.0.1,nine-router,hermes,caddy,xray,172.16.0.0/12,192.168.0.0/16,.ir'''

xray_service_block = ''
if proxy_enabled and proxy_mode == 'xray':
    xray_service_block = f'''  xray:
    image: teddysun/xray:latest
    container_name: ai-stack-xray
    restart: unless-stopped
    ports:
      - \"127.0.0.1:10808:10808\"
      - \"127.0.0.1:10809:10809\"
    volumes:
      - {stack_dir}/xray/config.json:/etc/xray/config.json:ro
    healthcheck:
      test: [\"CMD-SHELL\", \"nc -z 127.0.0.1 10808 || exit 1\"]
      interval: 30s
      timeout: 5s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: \"5m\"
        max-file: \"2\"
'''

# Build Hermes ports and healthcheck based on enabled optional features
hermes_ports = []
if dash_enabled:
    hermes_ports.append('      - \"127.0.0.1:9119:9119\"')
if api_enabled:
    hermes_ports.append('      - \"127.0.0.1:8642:8642\"')
hermes_ports_block = ('    ports:\n' + '\n'.join(hermes_ports)) if hermes_ports else ''

hermes_dash_flag = '1' if dash_enabled else '0'
hermes_api_flag = 'true' if api_enabled else 'false'
hermes_hc_cmd = 'curl -f http://localhost:9119/ || exit 1' if dash_enabled else 'pgrep -f hermes >/dev/null || exit 1'

# Decide whether Caddy runs
has_domains = False
domains_tsv = os.path.join(stack_dir, 'domains.tsv')
if os.path.exists(domains_tsv):
    with open(domains_tsv, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                has_domains = True
                break

run_caddy = (caddy_mode == 'true') or (caddy_mode == 'auto' and has_domains)
caddy_service_block = ''
if run_caddy:
    caddy_service_block = f'''
  caddy:
    image: caddy:2-alpine
    container_name: ai-stack-caddy
    restart: unless-stopped
    ports:
      - \"80:80\"
      - \"443:443\"
      - \"443:443/udp\"
    volumes:
      - {stack_dir}/Caddyfile:/etc/caddy/Caddyfile:ro
      - {stack_dir}/Caddyfile.d:/etc/caddy/Caddyfile.d:ro
      - {stack_dir}/certs:/etc/caddy/certs:ro
      - caddy_data:/data
      - caddy_config:/config
    healthcheck:
      test: [\"CMD-SHELL\", \"wget --no-verbose --tries=1 --spider http://localhost:80/ || exit 1\"]
      interval: 30s
      timeout: 5s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: \"5m\"
        max-file: \"2\"
'''

compose_content = f'''name: ai-stack

services:
{xray_service_block}  nine-router:
    image: decolua/9router:latest
    container_name: ai-stack-nine-router
    restart: unless-stopped
    ports:
      - \"127.0.0.1:20128:20128\"
    environment:
      - DATA_DIR=/app/data
      - NODE_OPTIONS=--max-old-space-size={router_max_mem}
      - NEXT_TELEMETRY_DISABLED=1
      - JWT_SECRET={jwt_secret}
      - API_KEY_SECRET={api_key_secret}
      - MACHINE_ID_SALT={machine_id_salt}
      - INITIAL_PASSWORD={initial_password}
      - REQUIRE_API_KEY={require_api_key}
      - AUTH_COOKIE_SECURE={auth_cookie_secure}
{proxy_env_block}
    volumes:
      - nine_router_data:/app/data
    healthcheck:
      test: [\"CMD-SHELL\", \"curl -f http://localhost:20128/api/health || exit 1\"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    logging:
      driver: json-file
      options:
        max-size: \"5m\"
        max-file: \"2\"

  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: ai-stack-hermes
    restart: unless-stopped
    command: gateway run
{hermes_ports_block}
    environment:
      - PYTHONDONTWRITEBYTECODE=1
      - PYTHONUNBUFFERED=1
      - PIP_NO_CACHE_DIR=1
      - MALLOC_TRIM_THRESHOLD_=65536
      - HERMES_DASHBOARD={hermes_dash_flag}
      - HERMES_DASHBOARD_BASIC_AUTH_USERNAME={hermes_user}
      - HERMES_DASHBOARD_BASIC_AUTH_PASSWORD={hermes_pass}
      - HERMES_DASHBOARD_BASIC_AUTH_SECRET={hermes_secret}
      - API_SERVER_ENABLED={hermes_api_flag}
      - API_SERVER_HOST=0.0.0.0
      - API_SERVER_KEY={api_server_key}
{proxy_env_block}
    volumes:
      - {stack_dir}/hermes:/opt/data
    healthcheck:
      test: [\"CMD-SHELL\", \"{hermes_hc_cmd}\"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: \"5m\"
        max-file: \"2\"
{caddy_service_block}
volumes:
  nine_router_data:
  caddy_data:
  caddy_config:
'''

with open(out, 'w', encoding='utf-8') as f:
    f.write(compose_content)
" "$compose_file" "$proxy_enabled" "$proxy_mode" "$proxy_url" \
  "$jwt_secret" "$api_key_secret" "$machine_id_salt" "$initial_password" \
  "$require_api_key" "$auth_cookie_secure" \
  "$hermes_user" "$hermes_pass" "$hermes_secret" "$api_server_key" \
  "$STACK_DIR" "$dash_enabled" "$api_enabled" "$caddy_enabled" "$router_max_mem"

    chmod 600 "$compose_file" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Stack Lifecycle Operations
# ------------------------------------------------------------------------------

# Verify environment and system dependencies before starting
stack_preflight() {
    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker not detected."
        install_docker_fallback
    fi
    
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running or current user lacks access (try: sudo usermod -aG docker $USER)."
    fi
    
    # Check port collisions (ignoring containers that belong to ai-stack)
    local check_ports=("80" "443" "20128" "9119" "8642")
    for port in "${check_ports[@]}"; do
        if command -v ss >/dev/null 2>&1; then
            if ss -tlpn | grep -q ":${port} " && ! ss -tlpn | grep ":${port} " | grep -q "docker-proxy"; then
                warn "Port $port is currently in use by an external host process!"
            fi
        fi
    done
}

# Record image digests for safe rollbacks
save_current_digests() {
    init_paths
    local current_file="$STACK_DIR/state/digests.current"
    docker compose -f "$STACK_DIR/docker-compose.yml" images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>/dev/null > "$current_file" || true
}

# Start the stack
stack_start() {
    init_paths
    stack_preflight
    
    if [[ "$(env_get "PROXY_MODE" "")" == "xray" ]]; then
        xray_generate_config
    fi
    
    generate_caddyfile
    generate_docker_compose
    
    info "Starting AI Stack containers..."
    docker compose -f "$STACK_DIR/docker-compose.yml" up -d --remove-orphans
    
    save_current_digests
    success "AI Stack is up."
}

# Stop the stack
stack_stop() {
    if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
        info "Stopping AI Stack..."
        docker compose -f "$STACK_DIR/docker-compose.yml" down
        success "Stack stopped."
    fi
}

# Restart the stack
stack_restart() {
    stack_stop
    stack_start
}

# View container logs
stack_logs() {
    local service="${1:-}"
    if [[ -z "$service" ]]; then
        docker compose -f "$STACK_DIR/docker-compose.yml" logs -f --tail=100
    else
        docker compose -f "$STACK_DIR/docker-compose.yml" logs -f --tail=100 "$service"
    fi
}

# Update images with automatic pre-backup and health verification
stack_update() {
    init_paths
    stack_preflight
    
    info "Creating automatic backup before update..."
    backup_create "pre-update" >/dev/null 2>&1 || true
    
    # Save previous image IDs
    if [[ -f "$STACK_DIR/state/digests.current" ]]; then
        cp "$STACK_DIR/state/digests.current" "$STACK_DIR/state/digests.prev"
    fi
    
    info "Pulling latest images..."
    if ! docker compose -f "$STACK_DIR/docker-compose.yml" pull; then
        warn "Direct image pull failed or timed out. Testing mirrors if in Iran..."
        if detect_iran_network; then
            configure_docker_mirrors || true
            docker compose -f "$STACK_DIR/docker-compose.yml" pull || die "Failed to pull updated images."
        else
            die "Failed to pull images. Check network connection."
        fi
    fi
    
    info "Recreating containers with updated images..."
    docker compose -f "$STACK_DIR/docker-compose.yml" up -d --remove-orphans
    
    # Health verification wait loop (up to 45 seconds)
    info "Verifying container health..."
    local healthy=0
    for ((i=1; i<=9; i++)); do
        sleep 5
        local unhealthy
        unhealthy=$(docker compose -f "$STACK_DIR/docker-compose.yml" ps --format "{{.Service}}: {{.Health}}" | grep -i "unhealthy" || true)
        if [[ -n "$unhealthy" ]]; then
            err "Service health check failed: $unhealthy"
            break
        fi
        local starting
        starting=$(docker compose -f "$STACK_DIR/docker-compose.yml" ps --format "{{.Health}}" | grep -i "starting" || true)
        if [[ -z "$starting" ]]; then
            healthy=1
            break
        fi
    done
    
    if [[ $healthy -eq 1 ]]; then
        save_current_digests
        success "AI Stack successfully updated and verified healthy."
    else
        warn "One or more containers did not report healthy. You can run: $SCRIPT_NAME rollback"
    fi
}

# Rollback to previously recorded image IDs
stack_rollback() {
    local prev_file="$STACK_DIR/state/digests.prev"
    if [[ ! -f "$prev_file" ]] || [[ ! -s "$prev_file" ]]; then
        die "No rollback state found in $prev_file."
    fi
    
    warn "Rolling back images to previous digests..."
    while read -r image_tag image_id; do
        if [[ -n "$image_tag" && -n "$image_id" ]]; then
            docker tag "$image_id" "$image_tag" 2>/dev/null || true
        fi
    done < "$prev_file"
    
    docker compose -f "$STACK_DIR/docker-compose.yml" up -d --force-recreate
    success "Rollback completed."
}

# ------------------------------------------------------------------------------
# Backup & Restore Subsystem
# ------------------------------------------------------------------------------

# Create consistent archive of all stack configuration, databases, and certificates
backup_create() {
    local label="${1:-manual}"
    init_paths
    
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local backup_file="$STACK_DIR/backups/backup-${timestamp}-${label}.tar.gz"
    local temp_stage
    temp_stage="$(mktemp -d -p /tmp ai-backup-XXXXXX)"
    
    info "Preparing stack backup ($label)..."
    
    # 1. Flush SQLite DB in 9Router if running
    if docker compose -f "$STACK_DIR/docker-compose.yml" ps --services --filter "status=running" 2>/dev/null | grep -q "^nine-router$"; then
        docker compose -f "$STACK_DIR/docker-compose.yml" exec -T nine-router sh -c "
            if command -v sqlite3 >/dev/null 2>&1 && [ -f /app/data/db/data.sqlite ]; then
                sqlite3 /app/data/db/data.sqlite 'PRAGMA wal_checkpoint(TRUNCATE);'
            fi
        " 2>/dev/null || true
    fi
    
    # 2. Export nine_router_data volume
    mkdir -p "$temp_stage/volumes/nine_router_data"
    docker run --rm -v ai-stack_nine_router_data:/source:ro -v "$temp_stage/volumes/nine_router_data":/target alpine \
        cp -a /source/. /target/ 2>/dev/null || true
        
    # 3. Export caddy_data volume (TLS certificates & ACME account)
    mkdir -p "$temp_stage/volumes/caddy_data"
    docker run --rm -v ai-stack_caddy_data:/source:ro -v "$temp_stage/volumes/caddy_data":/target alpine \
        cp -a /source/. /target/ 2>/dev/null || true
        
    # 4. Copy configuration files into stage
    mkdir -p "$temp_stage/config"
    cp -a "$STACK_DIR/.env" "$temp_stage/config/" 2>/dev/null || true
    cp -a "$STACK_DIR/domains.tsv" "$temp_stage/config/" 2>/dev/null || true
    cp -a "$STACK_DIR/certs" "$temp_stage/config/" 2>/dev/null || true
    cp -a "$STACK_DIR/xray" "$temp_stage/config/" 2>/dev/null || true
    cp -a "$STACK_DIR/hermes" "$temp_stage/config/" 2>/dev/null || true
    cp -a "$STACK_DIR/Caddyfile.d" "$temp_stage/config/" 2>/dev/null || true
    
    # 5. Pack archive
    tar -czf "$backup_file" -C "$temp_stage" .
    rm -rf "$temp_stage"
    
    # 6. Verify archive integrity
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        rm -f "$backup_file"
        die "Backup verification failed! Archive was corrupted."
    fi
    
    chmod 600 "$backup_file"
    success "Backup created: $backup_file ($(du -h "$backup_file" | cut -f1))"
    printf "%s\n" "$backup_file"
}

# List available backups
backup_list() {
    init_paths
    printf "\n%bAvailable Backups:%b\n" "$C_BOLD" "$C_RESET"
    printf "%-40s %-10s %-20s\n" "FILENAME" "SIZE" "DATE"
    printf "%-40s %-10s %-20s\n" "----------------------------------------" "----------" "--------------------"
    
    local found=0
    for f in "$STACK_DIR"/backups/backup-*.tar.gz; do
        [[ -f "$f" ]] || continue
        local size
        size=$(du -h "$f" | cut -f1)
        local d
        d=$(date -r "$f" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d'.' -f1 || echo "unknown")
        printf "%-40s %-10s %-20s\n" "$(basename "$f")" "$size" "$d"
        found=1
    done
    
    if [[ $found -eq 0 ]]; then
        printf "%b(No backup archives found in %s/backups)%b\n" "$C_DIM" "$STACK_DIR" "$C_RESET"
    fi
    printf "\n"
}

# Restore stack from a backup archive
backup_restore() {
    local target="${1:-}"
    init_paths
    
    if [[ -z "$target" ]]; then
        backup_list
        read -r -p "Enter backup filename to restore: " target
        if [[ -f "$STACK_DIR/backups/$target" ]]; then
            target="$STACK_DIR/backups/$target"
        fi
    fi
    
    if [[ ! -f "$target" ]]; then
        die "Backup file not found: $target"
    fi
    
    info "Validating backup archive integrity..."
    if ! tar -tzf "$target" >/dev/null 2>&1; then
        die "Invalid or corrupted backup archive: $target"
    fi
    
    warn "Restoring will overwrite current database, certificates, and stack configurations."
    if [[ "${ASSUME_YES:-false}" != "true" ]]; then
        read -r -p "Are you sure you want to proceed? [y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            info "Restore aborted by user."
            return 0
        fi
    fi
    
    stack_stop
    
    local temp_stage
    temp_stage="$(mktemp -d -p /tmp ai-restore-XXXXXX)"
    tar -xzf "$target" -C "$temp_stage"
    
    # 1. Restore configuration files
    if [[ -d "$temp_stage/config" ]]; then
        cp -a "$temp_stage/config/.env" "$STACK_DIR/.env" 2>/dev/null || true
        cp -a "$temp_stage/config/domains.tsv" "$STACK_DIR/domains.tsv" 2>/dev/null || true
        cp -a "$temp_stage/config/certs" "$STACK_DIR/" 2>/dev/null || true
        cp -a "$temp_stage/config/xray" "$STACK_DIR/" 2>/dev/null || true
        cp -a "$temp_stage/config/hermes" "$STACK_DIR/" 2>/dev/null || true
        cp -a "$temp_stage/config/Caddyfile.d" "$STACK_DIR/" 2>/dev/null || true
    fi
    
    # 2. Restore volumes
    if [[ -d "$temp_stage/volumes/nine_router_data" ]]; then
        docker run --rm -v ai-stack_nine_router_data:/target -v "$temp_stage/volumes/nine_router_data":/source:ro alpine \
            sh -c "rm -rf /target/* && cp -a /source/. /target/" 2>/dev/null || true
    fi
    
    if [[ -d "$temp_stage/volumes/caddy_data" ]]; then
        docker run --rm -v ai-stack_caddy_data:/target -v "$temp_stage/volumes/caddy_data":/source:ro alpine \
            sh -c "rm -rf /target/* && cp -a /source/. /target/" 2>/dev/null || true
    fi
    
    rm -rf "$temp_stage"
    
    # Fix permissions
    chmod 600 "$STACK_DIR/.env" 2>/dev/null || true
    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R 10000:10000 "$STACK_DIR/hermes" 2>/dev/null || true
    fi
    
    stack_start
    success "Stack successfully restored from $target"
}

# Install automated daily backup cron job
install_backup_cron() {
    local cron_job="0 3 * * * $SCRIPT_PATH backup create daily >/dev/null 2>&1"
    
    if crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH backup create" >/dev/null 2>&1; then
        info "Backup cron job already installed."
        return 0
    fi
    
    (crontab -l 2>/dev/null || true; printf "%s\n" "$cron_job") | crontab -
    success "Automated daily backup cron job installed (Runs daily at 03:00)."
}

# ------------------------------------------------------------------------------
# Status & Doctor Subsystem
# ------------------------------------------------------------------------------

stack_status() {
    init_paths
    printf "\n%b================ AI STACK STATUS ================%b\n" "$C_BOLD" "$C_RESET"
    
    # 1. Containers table
    printf "\n%bContainers:%b\n" "$C_BOLD" "$C_RESET"
    printf "%-25s %-15s %-12s %-20s\n" "SERVICE" "STATUS" "HEALTH" "PORTS"
    printf "%-25s %-15s %-12s %-20s\n" "-------------------------" "---------------" "------------" "--------------------"
    
    local services=("nine-router" "hermes" "caddy")
    if [[ "$(env_get "PROXY_MODE" "")" == "xray" ]]; then
        services+=("xray")
    fi
    
    for srv in "${services[@]}"; do
        local cname="ai-stack-${srv}"
        if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
            local state
            state=$(docker inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "unknown")
            local health
            health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$cname" 2>/dev/null || echo "n/a")
            local ports
            ports=$(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{$p}} {{end}}{{end}}' "$cname" 2>/dev/null || echo "")
            
            local state_col="$C_RESET"
            [[ "$state" == "running" ]] && state_col="$C_GREEN" || state_col="$C_RED"
            
            local health_col="$C_RESET"
            [[ "$health" == "healthy" ]] && health_col="$C_GREEN"
            [[ "$health" == "unhealthy" ]] && health_col="$C_RED"
            [[ "$health" == "starting" ]] && health_col="$C_YELLOW"
            
            printf "%-25s %b%-15s%b %b%-12s%b %-20s\n" "$srv" "$state_col" "$state" "$C_RESET" "$health_col" "$health" "$C_RESET" "$ports"
        else
            printf "%-25s %b%-15s%b %-12s %-20s\n" "$srv" "$C_DIM" "not created" "$C_RESET" "n/a" "-"
        fi
    done
    
    # 2. Proxy & Features info
    printf "\n"
    proxy_status
    printf "\n"
    features_status
    
    # 3. Domains summary
    domain_list
    
    # 4. Storage & Hermes info
    local disk_usage
    disk_usage=$(du -sh "$STACK_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    local active_model
    active_model=$(env_get "DEFAULT_MODEL" "nousresearch/hermes-3-llama-3.1-8b")
    
    printf "%bStack Directory:%b %s (%s)\n" "$C_BOLD" "$C_RESET" "$STACK_DIR" "$disk_usage"
    printf "%bHermes Model:%b    %s\n" "$C_BOLD" "$C_RESET" "$active_model"
    printf "%b9Router Admin:%b    http://localhost:20128/admin (Initial password: %s)\n" "$C_BOLD" "$C_RESET" "$(env_get "INITIAL_PASSWORD" "123456")"
    if [[ "$(env_get "HERMES_DASHBOARD_ENABLED" "true")" == "true" ]]; then
        printf "%bHermes Portal:%b    http://localhost:9119 (User: %s / Pass: %s)\n" "$C_BOLD" "$C_RESET" "$(env_get "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "admin")" "$(env_get "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" "admin123")"
    else
        printf "%bHermes Portal:%b    %bDisabled (Lightweight mode)%b\n" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    fi
    printf "\n"
}

stack_doctor() {
    init_paths
    printf "\n%b================ AI STACK DIAGNOSTIC DOCTOR ================%b\n" "$C_BOLD" "$C_RESET"
    local issues=0
    
    # 1. Host Resources
    info "Inspecting Host Resources..."
    local total_ram
    total_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    local avail_ram
    avail_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo "0")
    
    if [[ "$total_ram" -lt 1800 ]]; then
        warn "  Low total RAM: ${total_ram}MB. Hermes Agent gateway recommends at least 2GB RAM."
        ((issues++)) || true
    else
        success "  RAM: ${total_ram}MB total, ${avail_ram}MB available."
    fi
    
    local free_disk
    free_disk=$(df -m "$STACK_DIR" 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
    if [[ "$free_disk" -lt 2000 ]]; then
        warn "  Low disk space: ${free_disk}MB available on $STACK_DIR partition."
        ((issues++)) || true
    else
        success "  Disk space: ${free_disk}MB free."
    fi
    
    # 2. Docker & Compose
    info "Inspecting Docker Environment..."
    if command -v docker >/dev/null 2>&1; then
        local d_ver
        d_ver=$(docker --version 2>/dev/null | cut -d',' -f1)
        success "  $d_ver"
    else
        err "  Docker is not installed."
        ((issues++)) || true
    fi
    
    if docker compose version >/dev/null 2>&1; then
        local dc_ver
        dc_ver=$(docker compose version 2>/dev/null)
        success "  $dc_ver"
    else
        err "  Docker Compose v2 plugin is missing."
        ((issues++)) || true
    fi
    
    # 3. Network & Iranian Restrictions Inspection
    info "Inspecting Outbound Connectivity & Iran Network..."
    local country=""
    country=$(curl -s --max-time 3 https://api.country.is/ 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get("country", ""))' 2>/dev/null || true)
    [[ -n "$country" ]] && info "  Detected Origin Country: $country" || warn "  Could not determine origin country from IP."
    
    # Test DNS Poisoning
    local dns_status
    dns_status=$(python3 -c "
import socket
try:
    infos = socket.getaddrinfo('twitter.com', 80)
    for info in infos:
        if info[4][0].startswith('10.10.34.'):
            print('POISONED')
            break
    else:
        print('CLEAN')
except Exception:
    print('TIMEOUT')
" 2>/dev/null || echo "TIMEOUT")
    
    if [[ "$dns_status" == "POISONED" ]]; then
        err "  DNS Poisoning detected! Queries are being redirected to 10.10.34.x."
        warn "  Recommendation: Set reliable DNS resolvers (e.g. 1.1.1.1, 8.8.8.8) or enable Stack Proxy."
        ((issues++)) || true
    elif [[ "$dns_status" == "TIMEOUT" ]]; then
        warn "  DNS resolution test timed out or blocked."
    else
        success "  DNS resolution is unpoisoned."
    fi
    
    # Test Docker Hub Direct Access
    if curl -s --connect-timeout 3 -I https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
        success "  Direct Docker Hub access: Available"
    else
        warn "  Direct Docker Hub access: Blocked/Restricted."
        if [[ -f /etc/docker/daemon.json ]] && grep -q "registry-mirrors" /etc/docker/daemon.json 2>/dev/null; then
            success "  Docker registry mirrors: Configured in /etc/docker/daemon.json"
        else
            warn "  Docker registry mirrors: Not configured. Run: $SCRIPT_NAME iran setup-mirrors"
            ((issues++)) || true
        fi
    fi
    
    # Test AI & External Endpoints (Direct vs via Stack Proxy)
    info "Inspecting Outbound AI & External APIs..."
    local endpoints=("api.openai.com" "openrouter.ai" "api.anthropic.com" "api.telegram.org")
    local proxy_on
    proxy_on=$(env_get "PROXY_ENABLED" "false")
    for ep in "${endpoints[@]}"; do
        if [[ "$proxy_on" == "true" ]]; then
            if outbound_curl -s --connect-timeout 5 -I "https://${ep}" >/dev/null 2>&1; then
                success "  https://${ep}: Reachable via Stack Proxy ($(get_active_host_proxy))"
            elif curl -s --connect-timeout 4 -I "https://${ep}" >/dev/null 2>&1; then
                warn "  https://${ep}: Reachable directly, but Stack Proxy ($(get_active_host_proxy)) is not responding (is Xray running?)."
            else
                err "  https://${ep}: Unreachable via Stack Proxy ($(get_active_host_proxy)). Check Xray links or external proxy!"
                ((issues++)) || true
            fi
        else
            if curl -s --connect-timeout 4 -I "https://${ep}" >/dev/null 2>&1; then
                success "  https://${ep}: Reachable directly"
            else
                warn "  https://${ep}: Unreachable directly (Stack proxy is disabled; enable proxy to bypass restriction)."
                ((issues++)) || true
            fi
        fi
    done
    
    printf "\n"
    if [[ $issues -eq 0 ]]; then
        success "Doctor check completed: All systems healthy."
    else
        warn "Doctor check completed: Found $issues potential issue(s). Review recommendations above."
    fi
    printf "\n"
}

# ------------------------------------------------------------------------------
# Setup Wizard & Interactive UI
# ------------------------------------------------------------------------------

stack_setup() {
    init_paths
    ensure_stack_secrets
    
    printf "\n%b================ AI STACK INITIAL SETUP ================%b\n" "$C_BOLD" "$C_RESET"
    info "Setting up AI Stack at $STACK_DIR..."
    
    # 1. Profile selection
    local detected_profile="intl"
    if detect_iran_network; then
        detected_profile="iran"
    fi
    
    printf "\nSelect Deployment Environment:\n"
    printf "  1) Iran VPS (Docker mirrors, proxy routing, DNS poisoning mitigation) %s\n" "$([[ "$detected_profile" == "iran" ]] && printf "(Detected)" || printf "")"
    printf "  2) International VPS (Direct access to Docker Hub and AI APIs) %s\n" "$([[ "$detected_profile" == "intl" ]] && printf "(Detected)" || printf "")"
    read -r -p "Choice [1-2] (default $([[ "$detected_profile" == "iran" ]] && echo "1" || echo "2")): " prof_choice
    
    if [[ "${prof_choice:-}" == "1" ]] || { [[ -z "$prof_choice" ]] && [[ "$detected_profile" == "iran" ]]; }; then
        env_set "STACK_PROFILE" "iran"
        info "Configured for Iran environment."
        
        # Configure Docker mirrors if root
        if [[ "$(id -u)" -eq 0 ]]; then
            read -r -p "Configure Iranian Docker registry mirrors now? [Y/n]: " setup_mirr
            if [[ "${setup_mirr:-y}" =~ ^[Yy]$ ]]; then
                configure_docker_mirrors || true
            fi
        fi
        
        # Configure Proxy
        read -r -p "Configure Outbound Proxy / Xray now? [Y/n]: " setup_prx
        if [[ "${setup_prx:-y}" =~ ^[Yy]$ ]]; then
            printf "\nProxy Types:\n"
            printf "  1) Import Xray Share Link (vless://, vmess://, trojan://, ss://)\n"
            printf "  2) External SOCKS5 / HTTP Proxy URL\n"
            read -r -p "Choice [1-2]: " prx_choice
            if [[ "$prx_choice" == "2" ]]; then
                proxy_set_external ""
            else
                proxy_add_link ""
            fi
        fi
    else
        env_set "STACK_PROFILE" "intl"
        info "Configured for International environment."
    fi
    
    # 2. 9Router Initial Password
    printf "\n%b9Router Admin Password:%b\n" "$C_BOLD" "$C_RESET"
    local cur_pass
    cur_pass=$(env_get "INITIAL_PASSWORD" "123456")
    read -r -p "Set initial password (default: $cur_pass): " in_pass
    if [[ -n "$in_pass" ]]; then
        env_set "INITIAL_PASSWORD" "$in_pass"
    fi
    
    # 3. Hermes Optional Web UI & Credentials
    printf "\n%bHermes Agent Web UI (Optional):%b\n" "$C_BOLD" "$C_RESET"
    read -r -p "Enable Hermes Web UI Dashboard on port 9119? (Disable to save RAM) [Y/n]: " enable_dash
    if [[ "${enable_dash:-y}" =~ ^[Nn]$ ]]; then
        env_set "HERMES_DASHBOARD_ENABLED" "false"
        info "Hermes Web UI disabled (lightweight mode)."
    else
        env_set "HERMES_DASHBOARD_ENABLED" "true"
        local cur_huser
        cur_huser=$(env_get "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "admin")
        read -r -p "Dashboard username (default: $cur_huser): " in_huser
        env_set "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "${in_huser:-$cur_huser}"
        
        local cur_hpass
        cur_hpass=$(env_get "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" "admin123")
        read -r -p "Dashboard password (default: $cur_hpass): " in_hpass
        env_set "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" "${in_hpass:-$cur_hpass}"
    fi
    
    # 4. Default AI Model
    printf "\n%bDefault AI Model:%b\n" "$C_BOLD" "$C_RESET"
    local cur_model
    cur_model=$(env_get "DEFAULT_MODEL" "nousresearch/hermes-3-llama-3.1-8b")
    read -r -p "Model name (default: $cur_model): " in_model
    local final_model="${in_model:-$cur_model}"
    env_set "DEFAULT_MODEL" "$final_model"
    
    # Update Hermes config.yaml
    merge_hermes_config "$final_model" "$(env_get "INITIAL_PASSWORD" "123456")" "localhost"
    
    # 5. Domain Configuration
    read -r -p "Would you like to configure a domain name now? [y/N]: " setup_dom
    if [[ "$setup_dom" =~ ^[Yy]$ ]]; then
        domain_add "" "" ""
    fi
    
    # 6. Install shortcut
    install_shortcut
    
    # 7. Start Stack
    stack_start
    success "Setup completed successfully."
}

# Install 'aistack' CLI shortcut symlink
install_shortcut() {
    local target="/usr/local/bin/aistack"
    if [[ "$(id -u)" -ne 0 ]]; then
        target="${HOME}/.local/bin/aistack"
        mkdir -p "${HOME}/.local/bin"
    fi
    
    ln -sf "$SCRIPT_PATH" "$target" 2>/dev/null || true
    if [[ -L "$target" ]]; then
        success "Installed CLI shortcut: $target"
    fi
}

# Internal Self-Test Suite
run_selftest() {
    info "Running internal logic self-tests..."
    local test_dir
    test_dir="$(mktemp -d -p /tmp ai-selftest-XXXXXX)"
    local prev_stack="$STACK_DIR"
    STACK_DIR="$test_dir"
    init_paths
    
    # Test 1: Safe .env round-trip with special characters and quotes
    env_set "TEST_KEY1" "simple_value"
    env_set "TEST_KEY2" 'value with spaces and '\''single'\'' and "double" quotes & symbols=$!'
    
    local v1
    v1=$(env_get "TEST_KEY1")
    local v2
    v2=$(env_get "TEST_KEY2")
    
    [[ "$v1" == "simple_value" ]] || die "Self-test failed: .env key1 mismatch ($v1)"
    [[ "$v2" == 'value with spaces and '\''single'\'' and "double" quotes & symbols=$!' ]] || die "Self-test failed: .env key2 mismatch ($v2)"
    success "Self-test 1 (.env key/value escaping): PASSED"
    
    # Test 2: Share link parser
    local vless_test="vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?security=reality&sni=cdn.example.com&pbk=12345&type=tcp#TestNode"
    local ob
    ob=$(xray_parse_link "$vless_test" "node-1")
    echo "$ob" | grep -q '"protocol": "vless"' || die "Self-test failed: Xray VLESS parsing"
    echo "$ob" | grep -q '"serverName": "cdn.example.com"' || die "Self-test failed: Xray reality SNI"
    success "Self-test 2 (Xray link parser): PASSED"
    
    # Test 3: Hermes config merger
    merge_hermes_config "test-model-4b" "secret-key-123" "ai.test.domain"
    local cfg_content
    cfg_content=$(cat "$test_dir/hermes/config.yaml")
    echo "$cfg_content" | grep -q "default: test-model-4b" || die "Self-test failed: Hermes model merge"
    echo "$cfg_content" | grep -q "https://ai.test.domain" || die "Self-test failed: Hermes dashboard merge"
    success "Self-test 3 (Hermes config.yaml merge): PASSED"
    
    # Cleanup
    STACK_DIR="$prev_stack"
    rm -rf "$test_dir"
    success "All self-tests passed successfully."
}

# Interactive Menu Loop
interactive_menu() {
    while true; do
        printf "\n%b================ AI STACK MANAGER ================%b\n" "$C_BOLD" "$C_RESET"
        printf "  1) Stack Status & Resources\n"
        printf "  2) Initial Setup Wizard\n"
        printf "  3) Start / Restart Stack\n"
        printf "  4) Stop Stack\n"
        printf "  5) Domain Management (Add / Remove / List)\n"
        printf "  6) Proxy & Xray Management (Bypass Censorship)\n"
        printf "  7) Run Diagnostic Doctor\n"
        printf "  8) Backup & Restore (SQLite + SSL + Configs)\n"
        printf "  9) Update Stack Images (With Auto-Rollback)\n"
        printf " 10) View Container Logs\n"
        printf " 11) Optional Features & Lightweight Mode\n"
        printf "  0) Exit\n"
        printf "%s\n" "--------------------------------------------------"
        read -r -p "Select option [0-11]: " opt
        
        case "$opt" in
            1) stack_status ;;
            2) stack_setup ;;
            3) stack_restart ;;
            4) stack_stop ;;
            5)
                printf "\nDomain Menu:\n 1) List\n 2) Add\n 3) Remove\n"
                read -r -p "Choice: " d_opt
                case "$d_opt" in
                    1) domain_list ;;
                    2) domain_add "" "" "" ;;
                    3) domain_rm "" ;;
                esac
                ;;
            6)
                printf "\nProxy Menu:\n 1) Status\n 2) Add Xray Share Link\n 3) Set External URL\n 4) Clear Links\n 5) Disable\n 6) Show Host Proxy Env Vars\n"
                read -r -p "Choice: " p_opt
                case "$p_opt" in
                    1) proxy_status ;;
                    2) proxy_add_link "" ;;
                    3) proxy_set_external "" ;;
                    4) proxy_clear_links ;;
                    5) proxy_disable ;;
                    6) proxy_env || true ;;
                esac
                ;;
            7) stack_doctor ;;
            8)
                printf "\nBackup Menu:\n 1) Create Backup\n 2) List Backups\n 3) Restore Backup\n 4) Install Daily Cron\n"
                read -r -p "Choice: " b_opt
                case "$b_opt" in
                    1) backup_create "manual" ;;
                    2) backup_list ;;
                    3) backup_restore "" ;;
                    4) install_backup_cron ;;
                esac
                ;;
            9) stack_update ;;
            10) stack_logs "" ;;
            11)
                features_status
                printf "\nFeatures Menu:\n 1) Toggle Hermes Web UI (on/off)\n 2) Toggle Hermes API Server (on/off)\n 3) Set Caddy Mode (auto/on/off)\n 4) Set 9Router Max Memory (MB)\n"
                read -r -p "Choice: " f_opt
                case "$f_opt" in
                    1) read -r -p "Hermes Web UI [on/off]: " v; features_set dashboard "$v" ;;
                    2) read -r -p "Hermes API [on/off]: " v; features_set api "$v" ;;
                    3) read -r -p "Caddy Mode [auto/on/off]: " v; features_set caddy "$v" ;;
                    4) read -r -p "9Router Max Memory MB [e.g. 256]: " v; features_set memory "$v" ;;
                esac
                ;;
            0|q|Q) break ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# CLI Dispatcher
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF
AI Stack Manager v${VERSION}
Manage 9Router, Hermes Agent, Caddy reverse proxy, and Xray anti-censorship.

Usage:
  $SCRIPT_NAME [flags] [subcommand] [arguments...]

Flags:
  --dir <path>          Stack working directory (default: $DEFAULT_STACK_DIR)
  --profile <iran|intl> Force deployment profile (overrides auto-detection)
  -y, --yes             Assume yes for confirmations
  -h, --help            Show this help message
  -v, --version         Show script version

Subcommands:
  setup                 Run initial setup wizard
  status                Show running containers, health, domains, and proxy status
  start                 Start all services
  stop                  Stop all services
  restart               Restart all services
  logs [service]        Stream logs (e.g. 'manage.sh logs nine-router')
  doctor                Run diagnostics for host, RAM, DNS poisoning, and AI APIs
  update                Pull latest images with auto-backup and health verification
  rollback              Rollback to previous image digests if update failed

Domain Commands:
  domain list           List configured domains and their CDN status
  domain add [dom]      Add domain with automatic TLS or Origin certificate
  domain rm [dom]       Remove domain and reload Caddy
  domain sync           Regenerate Caddyfile and reload Caddy

Proxy Commands:
  proxy status          Show current proxy settings
  proxy add-link [url]  Import vless/vmess/trojan/ss link for Xray leastPing balancer
  proxy set-external [url] Set external SOCKS5/HTTP proxy URL
  proxy clear           Remove all imported links
  proxy enable/disable  Toggle stack proxy routing
  proxy env             Output exportable HTTP_PROXY/ALL_PROXY env vars for host shell
  proxy exec <cmd...>   Run a host command routed through the active stack proxy

Feature & Lightweight Mode Commands:
  features status                Show optional features and memory caps
  features dashboard <on|off>    Toggle Hermes Web UI (Port 9119)
  features api <on|off>          Toggle Hermes API server (Port 8642)
  features caddy <auto|on|off>   Set Caddy mode (auto = only runs when domains exist)
  features memory <MB>           Set 9Router V8 max memory limit in MB (default: 256)

Backup Commands:
  backup create [tag]   Create full consistent backup archive (SQLite + SSL + Config)
  backup list           List available backup files
  backup restore [file] Restore stack from backup archive
  cron                  Install automated daily backup cron job

Iran Utilities:
  iran detect           Check if server is under Iranian network restrictions
  iran setup-mirrors    Test and configure responsive Iranian Docker mirrors
  iran set-mtu [mtu]    Configure Docker daemon MTU (default: 1400)
  bundle export [file]  Export container images to offline tarball
  bundle import <file>  Import container images from offline tarball

Other:
  shortcut              Install 'aistack' command shortcut
  selftest              Run internal unit tests
EOF
}

# Parse top-level options
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            STACK_DIR="$2"
            shift 2
            ;;
        --profile)
            env_set "STACK_PROFILE" "$2"
            shift 2
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "AI Stack Manager v${VERSION}"
            exit 0
            ;;
        xray-parse-internal)
            # Internal call used by xray_generate_config
            xray_parse_link "$2" "$3"
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

# If no subcommand provided:
if [[ $# -eq 0 ]]; then
    if [[ -t 0 ]]; then
        interactive_menu
        exit 0
    else
        show_help
        exit 0
    fi
fi

CMD="$1"
shift

acquire_lock false

case "$CMD" in
    setup)
        stack_setup
        ;;
    status)
        stack_status
        ;;
    start)
        stack_start
        ;;
    stop)
        stack_stop
        ;;
    restart)
        stack_restart
        ;;
    logs)
        stack_logs "${1:-}"
        ;;
    doctor)
        stack_doctor
        ;;
    update)
        stack_update
        ;;
    rollback)
        stack_rollback
        ;;
    domain)
        sub="${1:-list}"
        shift || true
        case "$sub" in
            list) domain_list ;;
            add)  domain_add "${1:-}" "${2:-}" "${3:-}" ;;
            rm)   domain_rm "${1:-}" ;;
            sync) generate_caddyfile; caddy_reload ;;
            *)    die "Unknown domain subcommand: $sub" ;;
        esac
        ;;
    proxy)
        sub="${1:-status}"
        shift || true
        case "$sub" in
            status) proxy_status ;;
            add-link) proxy_add_link "${1:-}" ;;
            set-external) proxy_set_external "${1:-}" ;;
            clear) proxy_clear_links ;;
            enable) proxy_enable ;;
            disable) proxy_disable ;;
            env) proxy_env ;;
            exec) proxy_exec "$@" ;;
            *) die "Unknown proxy subcommand: $sub" ;;
        esac
        ;;
    features)
        sub="${1:-status}"
        shift || true
        case "$sub" in
            status) features_status ;;
            dashboard|api|caddy|memory) features_set "$sub" "${1:-}" ;;
            *) die "Unknown features subcommand: $sub" ;;
        esac
        ;;
    backup)
        sub="${1:-create}"
        shift || true
        case "$sub" in
            create) backup_create "${1:-manual}" ;;
            list)   backup_list ;;
            restore) backup_restore "${1:-}" ;;
            *)      die "Unknown backup subcommand: $sub" ;;
        esac
        ;;
    bundle)
        sub="${1:-export}"
        shift || true
        case "$sub" in
            export) bundle_export "${1:-}" ;;
            import) bundle_import "${1:-}" ;;
            *) die "Unknown bundle subcommand: $sub" ;;
        esac
        ;;
    iran)
        sub="${1:-detect}"
        shift || true
        case "$sub" in
            detect)
                if detect_iran_network; then
                    warn "Host is detected in Iran or subject to network restrictions."
                else
                    success "Host appears to have direct international access."
                fi
                ;;
            setup-mirrors) configure_docker_mirrors ;;
            set-mtu) configure_docker_mtu "${1:-1400}" ;;
            *) die "Unknown iran subcommand: $sub" ;;
        esac
        ;;
    shortcut)
        install_shortcut
        ;;
    cron)
        install_backup_cron
        ;;
    selftest)
        run_selftest
        ;;
    *)
        err "Unknown command: $CMD"
        show_help
        exit 1
        ;;
esac
