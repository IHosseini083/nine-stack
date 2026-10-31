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
# Logging & Smart TUI Engine (Zero external dependencies, flicker-free ANSI)
# ------------------------------------------------------------------------------
log()     { printf "%b\n" "$*"; }
info()    { printf "%b  ℹ %b%s\n" "$C_CYAN" "$C_RESET" "$*"; }
success() { printf "%b  ✔ %b%s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf "%b  ⚠ %b%s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf "%b  ✖ %b%s\n" "$C_RED" "$C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }

TUI_CHOICE=0

has_tty() {
    { true </dev/tty; } 2>/dev/null
}

is_interactive_tty() {
    [[ "${NO_TUI:-0}" != "1" ]] && [[ -t 1 ]] && has_tty
}

# Read a line from /dev/tty if available, fallback to stdin
tty_read() {
    if has_tty; then
        read "$@" </dev/tty
    else
        read "$@"
    fi
}

# Styled input prompt: tui_input "Prompt label" "default_value" result_var_name
tui_input() {
    local label="$1"
    local default_val="${2:-}"
    local __outvar="${3:-}"
    local val=""
    if [[ -n "$default_val" ]]; then
        printf "  %b▸%b %b%s%b %b[%s]%b: " "$C_CYAN" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" "$C_DIM" "$default_val" "$C_RESET"
    else
        printf "  %b▸%b %b%s%b: " "$C_CYAN" "$C_RESET" "$C_BOLD" "$label" "$C_RESET"
    fi
    tty_read -r val || val=""
    val="${val:-$default_val}"
    if [[ -n "$__outvar" ]]; then
        printf -v "$__outvar" "%s" "$val"
    else
        printf "%s\n" "$val"
    fi
}

# Interactive Yes/No confirmation: tui_confirm "Question?" [default_y_or_n]
tui_confirm() {
    local question="$1"
    local default_ans="${2:-y}"
    if [[ "${ASSUME_YES:-false}" == "true" ]]; then
        return 0
    fi
    if is_interactive_tty; then
        local pre=0
        [[ "$default_ans" =~ ^[Nn] ]] && pre=1
        TUI_DEFAULT_INDEX="$pre" tui_select "$question" "Yes, proceed" "No, cancel" || return 1
        [[ "$TUI_CHOICE" -eq 0 ]]
        return $?
    else
        local hint="[Y/n]"
        [[ "$default_ans" =~ ^[Nn] ]] && hint="[y/N]"
        local ans=""
        printf "  %b?%b %s %s: " "$C_YELLOW" "$C_RESET" "$question" "$hint"
        tty_read -r ans || ans="$default_ans"
        ans="${ans:-$default_ans}"
        [[ "$ans" =~ ^[Yy] ]]
    fi
}

# Flicker-free arrow-key selector: tui_select "Title" "Opt 1" "Opt 2" ...
# Sets global TUI_CHOICE (0-based index). Returns 0 on selection, 1 on q/Esc.
tui_select() {
    local title="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local cur="${TUI_DEFAULT_INDEX:-0}"
    TUI_DEFAULT_INDEX=0
    (( cur >= count || cur < 0 )) && cur=0

    if ! is_interactive_tty; then
        printf "\n  %b%s%b\n" "$C_BOLD" "$title" "$C_RESET"
        local i=0
        for ((i=0; i<count; i++)); do
            printf "    %d) %s\n" $((i+1)) "${options[$i]}"
        done
        local ans=""
        tty_read -r -p "  Select [1-${count}] (default $((cur+1))): " ans || ans=""
        if [[ "$ans" == "q" || "$ans" == "Q" || "$ans" == "0" ]]; then
            return 1
        fi
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= count )); then
            TUI_CHOICE=$((ans - 1))
        else
            TUI_CHOICE=$cur
        fi
        return 0
    fi

    printf "\n  %b▸ %s%b %b(↑/↓ move, Enter select, 1-%d quick-pick, q back)%b\n" \
        "$C_BOLD$C_CYAN" "$title" "$C_RESET" "$C_DIM" "$count" "$C_RESET"

    # Hide cursor during selection
    printf "\033[?25l" >/dev/tty 2>/dev/null || true

    local i
    for ((i=0; i<count; i++)); do
        printf "\n"
    done

    while true; do
        # Move up $count lines and redraw options in-place
        printf "\033[%dA" "$count"
        for ((i=0; i<count; i++)); do
            local num=$((i + 1))
            if (( i == cur )); then
                printf "\r\033[2K  %b❯ [%d] %s%b\n" "$C_BOLD$C_GREEN" "$num" "${options[$i]}" "$C_RESET"
            else
                printf "\r\033[2K    %b[%d]%b %s\n" "$C_DIM" "$num" "$C_RESET" "${options[$i]}"
            fi
        done

        local key=""
        IFS= read -rsn1 key </dev/tty || { printf "\033[?25h" >/dev/tty 2>/dev/null || true; return 1; }

        if [[ "$key" == $'\x1b' ]]; then
            local seq=""
            IFS= read -rsn2 -t 0.05 seq </dev/tty || seq=""
            case "$seq" in
                "[A"|"OA") cur=$(( (cur - 1 + count) % count )) ;;
                "[B"|"OB") cur=$(( (cur + 1) % count )) ;;
                "")
                    printf "\033[?25h" >/dev/tty 2>/dev/null || true
                    return 1
                    ;;
            esac
        elif [[ "$key" == "" ]]; then
            printf "\033[?25h" >/dev/tty 2>/dev/null || true
            TUI_CHOICE=$cur
            return 0
        elif [[ "$key" == "k" || "$key" == "K" ]]; then
            cur=$(( (cur - 1 + count) % count ))
        elif [[ "$key" == "j" || "$key" == "J" ]]; then
            cur=$(( (cur + 1) % count ))
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            printf "\033[?25h" >/dev/tty 2>/dev/null || true
            return 1
        elif [[ "$key" =~ ^[1-9]$ ]]; then
            local idx=$((key - 1))
            if (( idx < count )); then
                cur=$idx
                printf "\033[%dA" "$count"
                for ((i=0; i<count; i++)); do
                    local num=$((i + 1))
                    if (( i == cur )); then
                        printf "\r\033[2K  %b❯ [%d] %s%b\n" "$C_BOLD$C_GREEN" "$num" "${options[$i]}" "$C_RESET"
                    else
                        printf "\r\033[2K    %b[%d]%b %s\n" "$C_DIM" "$num" "$C_RESET" "${options[$i]}"
                    fi
                done
                printf "\033[?25h" >/dev/tty 2>/dev/null || true
                TUI_CHOICE=$cur
                return 0
            fi
        fi
    done
}

tui_pause() {
    if is_interactive_tty; then
        printf "\n  %bPress Enter or any key to continue...%b" "$C_DIM" "$C_RESET"
        local _k=""
        IFS= read -rsn1 _k </dev/tty || true
        printf "\r\033[2K"
    fi
}

# Run a command with an animated braille spinner when in an interactive TTY
tui_spin() {
    local msg="$1"
    shift
    if ! is_interactive_tty; then
        info "$msg"
        "$@"
        return $?
    fi

    local log_tmp
    log_tmp="$(mktemp -p /tmp ai-spin-XXXXXX)"
    "$@" >"$log_tmp" 2>&1 &
    local pid=$!
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local f=0

    printf "\033[?25l" >/dev/tty 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r\033[2K  %b%s%b %s" "$C_CYAN" "${frames[$f]}" "$C_RESET" "$msg"
        f=$(( (f + 1) % 10 ))
        sleep 0.08
    done

    local rc=0
    wait "$pid" || rc=$?
    printf "\r\033[2K\033[?25h" >/dev/tty 2>/dev/null || true

    if (( rc == 0 )); then
        success "$msg"
    else
        err "$msg (failed with exit code $rc)"
        cat "$log_tmp" >&2
    fi
    rm -f "$log_tmp"
    return $rc
}

# Render live compact header for the interactive TUI
tui_header() {
    init_paths
    ensure_stack_secrets

    # Fast single-call container check
    local running_names=""
    if command -v docker >/dev/null 2>&1; then
        running_names=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
    fi

    local b_router="${C_DIM}○ 9Router${C_RESET}"
    local b_caddy="${C_DIM}○ Caddy${C_RESET}"
    local b_xray="${C_DIM}○ Xray${C_RESET}"

    grep -q "^ai-stack-nine-router$" <<<"$running_names" && b_router="${C_GREEN}● 9Router${C_RESET}"
    grep -q "^ai-stack-caddy$" <<<"$running_names"       && b_caddy="${C_GREEN}● Caddy${C_RESET}"
    grep -q "^ai-stack-xray$" <<<"$running_names"        && b_xray="${C_GREEN}● Xray${C_RESET}"

    # Fast RAM reading from /proc/meminfo
    local mem_str="N/A"
    if [[ -r /proc/meminfo ]]; then
        mem_str=$(awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END {if(t>0) printf "%dM / %dM (%d%%)", (t-a)/1024, t/1024, ((t-a)*100)/t}' /proc/meminfo 2>/dev/null || echo "N/A")
    fi

    local profile
    profile=$(env_get "STACK_PROFILE" "auto")
    local prx_en
    prx_en=$(env_get "PROXY_ENABLED" "false")
    local prx_mode
    prx_mode=$(env_get "PROXY_MODE" "none")
    local prx_badge="${C_DIM}Direct (Off)${C_RESET}"
    if [[ "$prx_en" == "true" ]]; then
        if [[ "$prx_mode" == "xray" ]]; then
            local ncnt=0
            [[ -f "$STACK_DIR/xray/links.txt" ]] && ncnt=$(grep -cve '^\s*$' "$STACK_DIR/xray/links.txt" 2>/dev/null || echo 0)
            prx_badge="${C_GREEN}Xray (${ncnt} nodes)${C_RESET}"
        elif [[ "$prx_mode" == "external" ]]; then
            prx_badge="${C_GREEN}External Proxy${C_RESET}"
        fi
    fi

    local caddy_en
    caddy_en=$(env_get "CADDY_ENABLED" "auto")
    local r_mem
    r_mem=$(env_get "NINE_ROUTER_MAX_MEM" "256")
    local req_key
    req_key=$(env_get "REQUIRE_API_KEY" "false")

    local dom_cnt=0
    [[ -f "$STACK_DIR/domains.tsv" ]] && dom_cnt=$(grep -cve '^\s*$' "$STACK_DIR/domains.tsv" 2>/dev/null || echo 0)

    local key_pill="${C_DIM}Off (sk_9router)${C_RESET}"
    [[ "$req_key" == "true" ]] && key_pill="${C_GREEN}Enforced${C_RESET}"

    printf "\n"
    printf "  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_CYAN" "$C_RESET"
    printf "  %b│%b  %b⚡ NINE-STACK MANAGER v%-8s%b  %bRAM:%b %-27s %b│%b\n" \
        "$C_CYAN" "$C_RESET" "$C_BOLD$C_WHITE" "$VERSION" "$C_RESET" "$C_DIM" "$C_RESET" "$mem_str" "$C_CYAN" "$C_RESET"
    printf "  %b├──────────────────────────────────────────────────────────────────────┤%b\n" "$C_CYAN" "$C_RESET"
    printf "  %b│%b  %bServices:%b  %b      %b      %b\n" \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$b_router" "$b_caddy" "$b_xray"
    printf "  %b│%b  %bNetwork:%b   Profile: %b%-6s%b │ Proxy: %b │ Domains: %b%d%b\n" \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$profile" "$C_RESET" "$prx_badge" "$C_BOLD" "$dom_cnt" "$C_RESET"
    printf "  %b│%b  %bFeatures:%b  Caddy: %b%s%b │ V8 Heap: %b%sM%b │ API Key: %b\n" \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$caddy_en" "$C_RESET" "$C_CYAN" "$r_mem" "$C_RESET" "$key_pill"
    printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n" "$C_CYAN" "$C_RESET"
}

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
        if ! flock -n "$LOCK_FD"; then
            info "Waiting for stack lock..."
            flock "$LOCK_FD"
        fi
    fi
}

release_lock() {
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec $LOCK_FD>&-" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

cleanup() {
    local exit_code=$?
    { printf "\033[?25h" >/dev/tty; } 2>/dev/null || true
    release_lock
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Path & Directory Initialization
# ------------------------------------------------------------------------------
init_paths() {
    mkdir -p "$STACK_DIR"/{certs,backups,state,Caddyfile.d,xray}
    chmod 700 "$STACK_DIR" 2>/dev/null || true
    chmod 700 "$STACK_DIR/certs" "$STACK_DIR/backups" 2>/dev/null || true
    
    # Touch state files if missing
    touch "$STACK_DIR/.env"
    touch "$STACK_DIR/domains.tsv"
    touch "$STACK_DIR/Caddyfile.d/custom"
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
    
    # Defaults for critical 9Router options
    if [[ -z "$(env_get "REQUIRE_API_KEY" "")" ]]; then
        env_set "REQUIRE_API_KEY" "false"
    fi
    if [[ -z "$(env_get "INITIAL_PASSWORD" "")" ]]; then
        env_set "INITIAL_PASSWORD" "123456"
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
    if [[ -z "$(env_get "CADDY_ENABLED" "")" ]]; then
        env_set "CADDY_ENABLED" "auto"
    fi
    if [[ -z "$(env_get "NINE_ROUTER_MAX_MEM" "")" ]]; then
        env_set "NINE_ROUTER_MAX_MEM" "256"
    fi
}

# ------------------------------------------------------------------------------
# 9Router Client Setup & API Access Subsystem
# ------------------------------------------------------------------------------
client_access_info() {
    init_paths
    ensure_stack_secrets
    local rpass
    rpass=$(env_get "INITIAL_PASSWORD" "123456")
    local req_key
    req_key=$(env_get "REQUIRE_API_KEY" "false")
    local srv_ip=""
    if command -v ip >/dev/null 2>&1; then
        srv_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
    fi
    if [[ -z "$srv_ip" ]] && command -v hostname >/dev/null 2>&1; then
        srv_ip=$(hostname -i 2>/dev/null | awk '{print $1; exit}' || true)
    fi
    [[ -z "$srv_ip" ]] && srv_ip="YOUR_VPS_IP"

    local primary_domain=""
    if [[ -s "$STACK_DIR/domains.tsv" ]]; then
        primary_domain=$(awk -F'\t' '!/^#/ && NF>=1 {print $1; exit}' "$STACK_DIR/domains.tsv" 2>/dev/null || true)
    fi

    local api_url="http://127.0.0.1:20128/v1"
    local admin_url="http://127.0.0.1:20128/admin"
    if [[ -n "$primary_domain" ]]; then
        api_url="https://${primary_domain}/v1"
        admin_url="https://${primary_domain}/admin"
    fi

    printf "\n  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_CYAN" "$C_RESET"
    printf "  %b│%b  %b🔌 9ROUTER CLIENT SETUP & API ACCESS GUIDE%b                            %b│%b\n" "$C_CYAN" "$C_RESET" "$C_BOLD$C_WHITE" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n" "$C_CYAN" "$C_RESET"

    printf "\n  %b1. 9Router Endpoints & Credentials:%b\n" "$C_BOLD" "$C_RESET"
    printf "     • Web Admin UI:     %b%s%b\n" "$C_GREEN" "$admin_url" "$C_RESET"
    printf "       Initial Password: %b%s%b\n" "$C_YELLOW" "$rpass" "$C_RESET"
    printf "     • OpenAI Base URL:  %b%s%b\n" "$C_GREEN" "$api_url" "$C_RESET"
    if [[ "$req_key" == "true" ]]; then
        printf "     • API Key:          %bCustom%b (Manage & generate keys in 9Router UI)\n" "$C_YELLOW" "$C_RESET"
    else
        printf "     • Default API Key:  %bsk_9router%b (Or create custom keys in 9Router UI)\n" "$C_CYAN" "$C_RESET"
    fi

    printf "\n  %b2. How to Connect Hermes Agent (Manual Setup):%b\n" "$C_BOLD" "$C_RESET"
    printf "     On the client/host running Hermes Agent, configure it with:\n"
    printf "     %bhermes config set model.provider custom%b\n" "$C_CYAN" "$C_RESET"
    printf "     %bhermes config set model.base_url \"%s\"%b\n" "$C_CYAN" "$api_url" "$C_RESET"
    printf "     %bhermes config set model.api_key \"sk_9router\"%b\n" "$C_CYAN" "$C_RESET"
    printf "     %bhermes config set model.default \"<model-name>\"%b  # e.g. gpt-4o, claude-3-5-sonnet\n" "$C_CYAN" "$C_RESET"
    printf "     %bhermes chat%b\n" "$C_GREEN" "$C_RESET"

    printf "\n  %b3. How to Connect Cursor / Cline / Roo / Claude Code:%b\n" "$C_BOLD" "$C_RESET"
    printf "     • Provider / API:   OpenAI Compatible\n"
    printf "     • Base URL:         %b%s%b\n" "$C_GREEN" "$api_url" "$C_RESET"
    printf "     • API Key:          %bsk_9router%b\n" "$C_GREEN" "$C_RESET"

    printf "\n  %b4. SSH Port-Forwarding (If domain is not configured):%b\n" "$C_BOLD" "$C_RESET"
    printf "     Run this on your laptop to securely forward 9Router ports:\n"
    printf "     %bssh -N -L 20128:127.0.0.1:20128 root@%s%b\n" "$C_CYAN" "$srv_ip" "$C_RESET"
    printf "     Then access locally at: %bhttp://localhost:20128/admin%b and %bhttp://localhost:20128/v1%b\n" "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET"

    printf "\n  %b5. Quick Connection Test (cURL):%b\n" "$C_BOLD" "$C_RESET"
    printf "     %bcurl -s %s/models -H \"Authorization: Bearer sk_9router\"%b\n\n" "$C_DIM" "$api_url" "$C_RESET"
}

# Compatibility wrapper when user runs 'aistack hermes ...'
hermes_cli() {
    info "Hermes Agent runs manually/externally in this architecture."
    client_access_info
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
        tui_input "External proxy URL (e.g. socks5://127.0.0.1:1080 or http://10.0.0.1:8080)" "$(env_get "PROXY_URL" "")" url
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
        tui_input "Paste Xray share link (vless://, vmess://, trojan://, ss://)" "" link
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

provider = 'Direct DNS'
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
    provider = 'Unresolved'

print(provider)
" "$domain"
}

# Print a clear visual guide explaining Domain Routing and SSL/TLS Modes
domain_explain_guide() {
    printf "\n  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_CYAN" "$C_RESET"
    printf "  %b│%b  %b🌐 DOMAIN ROUTING & SSL/TLS QUICK GUIDE%b                             %b│%b\n" "$C_CYAN" "$C_RESET" "$C_BOLD$C_WHITE" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b├──────────────────────────────────────────────────────────────────────┤%b\n" "$C_CYAN" "$C_RESET"
    printf "  %b│%b  %b1. What Does a Domain Expose?%b                                       %b│%b\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b     All configured domains route directly to %b9Router%b:                 %b│%b\n" "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b     • %bhttps://<domain>/admin%b  → 9Router Web Admin UI                   %b│%b\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b     • %bhttps://<domain>/v1/*%b   → OpenAI-Compatible AI API Endpoint      %b│%b\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b├──────────────────────────────────────────────────────────────────────┤%b\n" "$C_CYAN" "$C_RESET"
    printf "  %b│%b  %b2. Which SSL / TLS Mode Should I Pick?%b                              %b│%b\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b     • %bAuto TLS (Let's Encrypt / ZeroSSL)%b:                            %b│%b\n" "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b       Best when DNS A-record points directly to this VPS IP (or      %b│%b\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b       Cloudflare/Arvan proxy cloud icon is Grey / DNS-Only).         %b│%b\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b     • %bOrigin Certificate (Cloudflare / ArvanCloud CDN)%b:              %b│%b\n" "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b       Best when CDN Orange Cloud is ON with 'Full (Strict)' SSL.     %b│%b\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b     • %bInternal Self-Signed%b: For LAN, Tailscale, or private testing.  %b│%b\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n" "$C_CYAN" "$C_RESET"
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
                
            # All domains proxy directly to 9Router
            lines.append('    reverse_proxy nine-router:20128')
            lines.append('}')
            lines.append('')

if not has_domains:
    # Default fallback block for port 80/443 when no domain configured yet
    lines.append(':80 {')
    lines.append('    respond \"9Router Stack is running. Add a domain using: aistack domain add\" 200')
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
    
    printf "\n%bConfigured Domains & Routes:%b\n" "$C_BOLD" "$C_RESET"
    printf "  %-28s %-22s %-12s %-14s\n" "DOMAIN" "ROUTED TARGET" "TLS MODE" "DNS / CDN"
    printf "  %-28s %-22s %-12s %-14s\n" "----------------------------" "----------------------" "------------" "--------------"
    
    local count=0
    while IFS=$'\t' read -r dom srv tls cert key || [[ -n "$dom" ]]; do
        [[ -z "$dom" || "$dom" =~ ^# ]] && continue
        local cdn
        cdn=$(check_cdn_provider "$dom")
        printf "  %-28s %-22s %-12s %-14s\n" "$dom" "9Router (:20128)" "$tls" "$cdn"
        ((count++)) || true
    done < "$domains_tsv"
    
    if [[ $count -eq 0 ]]; then
        printf "  %b(No custom domains configured — 9Router listens on 127.0.0.1:20128 only)%b\n" "$C_DIM" "$C_RESET"
    fi
    printf "\n"
}

# Add or update a domain
domain_add() {
    init_paths
    local domain="${1:-}"
    local tls_mode="${2:-}"
    local service="9router"
    
    if [[ -z "$domain" ]]; then
        domain_explain_guide
        printf "\n"
        tui_input "Enter domain or subdomain (e.g. ai.example.com, leave empty to cancel)" "" domain
    fi
    domain=$(printf "%s" "$domain" | sed -E 's#^https?://##; s#/.*$##' | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    
    if [[ -z "$domain" ]]; then
        warn "Domain setup canceled."
        return 1
    fi
    
    if [[ ! "$domain" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
        warn "Invalid domain format: '$domain' (expected e.g. ai.example.com)."
        return 1
    fi
    
    # If domain already exists, offer to update/replace it in interactive mode
    if grep -q "^${domain}[[:space:]]" "$STACK_DIR/domains.tsv" 2>/dev/null; then
        if is_interactive_tty && [[ -z "${2:-}" ]]; then
            if tui_confirm "Domain '$domain' is already configured. Update its SSL settings?" "y"; then
                sed -i "/^${domain}[[:space:]]/d" "$STACK_DIR/domains.tsv"
            else
                return 1
            fi
        else
            warn "Domain $domain is already configured."
            return 1
        fi
    fi
    
    # Inspect DNS & CDN
    local cdn
    cdn=$(check_cdn_provider "$domain")
    if [[ "$cdn" == "Unresolved" ]]; then
        warn "DNS check: '$domain' does not resolve to an IP yet (make sure an A record points to this server)."
    else
        info "DNS check: '$domain' resolves via $cdn"
    fi
    
    if [[ -z "$tls_mode" ]]; then
        local pre_tls=0
        if [[ "$cdn" == "Cloudflare" ]] || [[ "$cdn" == "ArvanCloud" ]]; then
            info "CDN ($cdn) proxy detected: choose 'Origin Certificate' for Full (Strict) SSL, or 'Auto TLS' if DNS-only."
            pre_tls=1
        fi
        TUI_DEFAULT_INDEX="$pre_tls" tui_select "Select SSL/TLS Certificate Mode for $domain" \
            "Auto TLS (Let's Encrypt / ZeroSSL) — Automatic free SSL (Requires ports 80/443 open)" \
            "Origin Certificate (Cloudflare/Arvan) — Paste PEM cert & private key from CDN panel" \
            "Internal Self-Signed TLS            — For local networks, Tailscale, or testing" || return 1
        case "$TUI_CHOICE" in
            1) tls_mode="origin" ;;
            2) tls_mode="internal" ;;
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
        
        printf "\n  %b▸ Paste Origin Certificate PEM for %s (press Enter on an empty line when done):%b\n" "$C_BOLD$C_CYAN" "$domain" "$C_RESET"
        local cert_content=""
        while IFS= tty_read -r line; do
            [[ -z "$line" && "$cert_content" =~ -----END[[:space:]]CERTIFICATE----- ]] && break
            cert_content+="$line"$'\n'
        done
        if [[ ! "$cert_content" =~ -----BEGIN[[:space:]]CERTIFICATE----- ]]; then
            warn "Invalid certificate PEM. Aborting domain setup."
            return 1
        fi
        printf "%s" "$cert_content" > "$cert_file"
        
        printf "\n  %b▸ Paste Origin Private Key PEM for %s (press Enter on an empty line when done):%b\n" "$C_BOLD$C_CYAN" "$domain" "$C_RESET"
        local key_content=""
        while IFS= tty_read -r line; do
            [[ -z "$line" && "$key_content" =~ -----END[[:space:]].*PRIVATE[[:space:]]KEY----- ]] && break
            key_content+="$line"$'\n'
        done
        if [[ ! "$key_content" =~ PRIVATE[[:space:]]KEY----- ]]; then
            warn "Invalid private key PEM. Aborting domain setup."
            return 1
        fi
        printf "%s" "$key_content" > "$key_file"
        chmod 600 "$key_file"
    fi
    
    printf "%s\t%s\t%s\t%s\t%s\n" "$domain" "$service" "$tls_mode" "$cert_file" "$key_file" >> "$STACK_DIR/domains.tsv"
    generate_caddyfile
    
    generate_docker_compose
    if ! docker compose -f "$STACK_DIR/docker-compose.yml" ps --services --filter "status=running" 2>/dev/null | grep -q "^caddy$"; then
        if docker compose -f "$STACK_DIR/docker-compose.yml" ps --services --filter "status=running" 2>/dev/null | grep -q "^nine-router$"; then
            info "Starting Caddy reverse proxy for newly added domain..."
            docker compose -f "$STACK_DIR/docker-compose.yml" up -d caddy
        fi
    else
        caddy_reload
    fi
    success "Domain https://$domain configured (Routes to 9Router, TLS: $tls_mode)."
}

# Remove a domain
domain_rm() {
    init_paths
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        local dom_list=()
        while IFS=$'\t' read -r dom srv tls _ || [[ -n "$dom" ]]; do
            [[ -z "$dom" || "$dom" =~ ^# ]] && continue
            dom_list+=("$dom ($srv, $tls)")
        done < "$STACK_DIR/domains.tsv"
        if [[ ${#dom_list[@]} -eq 0 ]]; then
            warn "No domains configured to remove."
            return 0
        fi
        tui_select "Select domain to remove" "${dom_list[@]}" || return 0
        domain="${dom_list[$TUI_CHOICE]%% *}"
    fi
    domain=$(printf "%s" "$domain" | tr '[:upper:]' '[:lower:]' | tr -d ' /')
    
    if ! grep -q "^${domain}[[:space:]]" "$STACK_DIR/domains.tsv" 2>/dev/null; then
        warn "Domain $domain not found."
        return 1
    fi
    
    sed -i "/^${domain}[[:space:]]/d" "$STACK_DIR/domains.tsv"
    rm -rf "$STACK_DIR/certs/$domain"
    generate_caddyfile
    generate_docker_compose
    caddy_reload
    success "Domain $domain removed."
}

# ------------------------------------------------------------------------------
# Optional Features & Lightweight Mode Subsystem
# ------------------------------------------------------------------------------

features_status() {
    init_paths
    ensure_stack_secrets
    local caddy_en
    caddy_en=$(env_get "CADDY_ENABLED" "auto")
    local router_mem
    router_mem=$(env_get "NINE_ROUTER_MAX_MEM" "256")
    local req_key
    req_key=$(env_get "REQUIRE_API_KEY" "false")
    
    printf "%bOptional Features & Resource Limits:%b\n" "$C_BOLD" "$C_RESET"
    printf "  Caddy Reverse Proxy:        %s\n" "$caddy_en (auto = runs only when domains exist)"
    printf "  9Router V8 Heap Cap:        %s MB\n" "$router_mem"
    printf "  Require API Key Auth:       %s\n" "$([[ "$req_key" == "true" ]] && printf "%bEnforced%b" "$C_GREEN" "$C_RESET" || printf "%bOff (Default sk_9router permitted)%b" "$C_YELLOW" "$C_RESET")"
}

features_set() {
    init_paths
    local feature="${1:-}"
    local val="${2:-}"
    
    case "$feature" in
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
        auth|require-key|require_key)
            case "$val" in
                on|true|1)  env_set "REQUIRE_API_KEY" "true"; success "API key enforcement enabled." ;;
                off|false|0) env_set "REQUIRE_API_KEY" "false"; success "API key enforcement disabled (default key permitted)." ;;
                *) die "Usage: $SCRIPT_NAME features require-key <on|off>" ;;
            esac
            ;;
        *)
            die "Usage: $SCRIPT_NAME features <status|caddy|memory|require-key> [value]"
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

stack_dir = sys.argv[11]
caddy_mode = sys.argv[12]
router_max_mem = sys.argv[13]

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
      - NO_PROXY=localhost,127.0.0.1,nine-router,caddy,xray,172.16.0.0/12,192.168.0.0/16,.ir
      - no_proxy=localhost,127.0.0.1,nine-router,caddy,xray,172.16.0.0/12,192.168.0.0/16,.ir'''

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
  "$STACK_DIR" "$caddy_enabled" "$router_max_mem"

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
    local check_ports=("80" "443" "20128")
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
    
    local services=("nine-router" "caddy")
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
    
    # 4. Storage & 9Router info
    local disk_usage
    disk_usage=$(du -sh "$STACK_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    
    printf "%bStack Directory:%b %s (%s)\n" "$C_BOLD" "$C_RESET" "$STACK_DIR" "$disk_usage"
    printf "%b9Router Admin:%b   http://localhost:20128/admin (Initial password: %s)\n" "$C_BOLD" "$C_RESET" "$(env_get "INITIAL_PASSWORD" "123456")"
    printf "%bOpenAI API Base:%b http://localhost:20128/v1\n" "$C_BOLD" "$C_RESET"
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
    
    if [[ "$total_ram" -lt 950 ]]; then
        warn "  Low total RAM: ${total_ram}MB. 9Router + Caddy recommend at least 1GB RAM."
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
    
    printf "\n"
    printf "  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_CYAN" "$C_RESET"
    printf "  %b│%b  %b🚀 NINE-STACK SMART SETUP WIZARD%b                                   %b│%b\n" "$C_CYAN" "$C_RESET" "$C_BOLD$C_WHITE" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b│%b  %bDirectory:%b %-56s %b│%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET" "$STACK_DIR" "$C_CYAN" "$C_RESET"
    printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n" "$C_CYAN" "$C_RESET"
    
    # Step 1: Profile selection
    local detected_profile="intl"
    local pre_prof=1
    if detect_iran_network; then
        detected_profile="iran"
        pre_prof=0
    fi
    
    local iran_tag=""
    local intl_tag=""
    [[ "$detected_profile" == "iran" ]] && iran_tag=" (Auto-Detected)" || intl_tag=" (Auto-Detected)"
    
    TUI_DEFAULT_INDEX="$pre_prof" tui_select "Step 1/5 — Select Server Network Environment" \
        "Iran VPS          — Anti-censorship, Docker mirrors, DNS poisoning shield${iran_tag}" \
        "International VPS — Direct connection to Docker Hub & AI APIs${intl_tag}" || return 1
    
    if [[ "$TUI_CHOICE" -eq 0 ]]; then
        env_set "STACK_PROFILE" "iran"
        success "Environment set to: Iran VPS"
        
        if [[ "$(id -u)" -eq 0 ]]; then
            if tui_confirm "Benchmark & configure Iranian Docker registry mirrors now?" "y"; then
                configure_docker_mirrors || true
            fi
        fi
        
        tui_select "Configure Outbound Proxy for AI & External Traffic" \
            "Import Xray Share Link (vless://, vmess://, trojan://, ss://)" \
            "Use External Proxy URL (socks5:// or http://)" \
            "Skip proxy setup for now" || true
        case "$TUI_CHOICE" in
            0)
                while true; do
                    proxy_add_link "" || true
                    if ! tui_confirm "Add another Xray node to the leastPing balancer?" "n"; then
                        break
                    fi
                done
                ;;
            1)
                proxy_set_external "" || true
                ;;
            *)
                info "Skipped proxy setup (you can configure it anytime via 'aistack proxy')."
                ;;
        esac
    else
        env_set "STACK_PROFILE" "intl"
        success "Environment set to: International VPS"
    fi
    
    # Step 2: Resource & Memory Profile
    tui_select "Step 2/5 — Select 9Router V8 Heap Memory Cap" \
        "256 MB — Balanced Default (Recommended for 1GB–2GB RAM VPS)" \
        "192 MB — Ultra-Lightweight (Minimal memory footprint)" \
        "512 MB — High Concurrency (For high-load multi-client VPS)" || return 1
    
    case "$TUI_CHOICE" in
        1)
            env_set "NINE_ROUTER_MAX_MEM" "192"
            success "Profile: Ultra-Lightweight (192MB heap cap)."
            ;;
        2)
            env_set "NINE_ROUTER_MAX_MEM" "512"
            success "Profile: High Concurrency (512MB heap cap)."
            ;;
        *)
            env_set "NINE_ROUTER_MAX_MEM" "256"
            success "Profile: Balanced Default (256MB heap cap)."
            ;;
    esac
    
    # Step 3: 9Router Credentials & API Key Enforcement
    printf "\n  %b▸ Step 3/5 — 9Router Credentials & Authentication%b\n" "$C_BOLD$C_CYAN" "$C_RESET"
    local cur_pass
    cur_pass=$(env_get "INITIAL_PASSWORD" "123456")
    local in_pass=""
    tui_input "9Router Admin UI Password" "$cur_pass" in_pass
    env_set "INITIAL_PASSWORD" "$in_pass"
    
    if tui_confirm "Enforce strict API keys? (If no, sk_9router works out of the box)" "n"; then
        env_set "REQUIRE_API_KEY" "true"
        success "API key enforcement enabled."
    else
        env_set "REQUIRE_API_KEY" "false"
        success "Permissive mode enabled (Default key 'sk_9router' accepted)."
    fi
    
    # Step 4: Domain Configuration
    if tui_confirm "Step 4/5 — Would you like to configure a custom domain & SSL now?" "n"; then
        domain_add "" "" || true
    fi
    
    # Step 5: Install CLI shortcut & Start Stack
    printf "\n  %b▸ Step 5/5 — Launching Stack Services%b\n" "$C_BOLD$C_CYAN" "$C_RESET"
    install_shortcut
    stack_start
    
    printf "\n"
    printf "  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_GREEN" "$C_RESET"
    printf "  %b│%b  %b✔ SETUP COMPLETED SUCCESSFULLY%b                                     %b│%b\n" "$C_GREEN" "$C_RESET" "$C_BOLD$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET"
    printf "  %b├──────────────────────────────────────────────────────────────────────┤%b\n" "$C_GREEN" "$C_RESET"
    printf "  %b│%b  • %b9Router Admin:%b  http://localhost:20128/admin (Pass: %s)\n" "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$(env_get "INITIAL_PASSWORD" "123456")"
    printf "  %b│%b  • %bOpenAI API Base:%b http://localhost:20128/v1 (Key: sk_9router)\n" "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf "  %b│%b  • %bManage Stack:%b   Run %baistack%b anytime to open the interactive TUI\n" "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n" "$C_GREEN" "$C_RESET"
    client_access_info
}

# Install 'aistack' and 'ninestack' CLI shortcut symlinks
install_shortcut() {
    local bin_dir="/usr/local/bin"
    if [[ "$(id -u)" -ne 0 ]]; then
        bin_dir="${HOME}/.local/bin"
        mkdir -p "$bin_dir"
    fi
    
    ln -sf "$SCRIPT_PATH" "$bin_dir/aistack" 2>/dev/null || true
    ln -sf "$SCRIPT_PATH" "$bin_dir/ninestack" 2>/dev/null || true
    ln -sf "$SCRIPT_PATH" "$bin_dir/hermesstack" 2>/dev/null || true
    if [[ -L "$bin_dir/aistack" ]]; then
        success "Installed CLI shortcuts: $bin_dir/aistack & $bin_dir/ninestack"
    fi
}

# Uninstall NineStack (Standard or Complete Purge)
stack_uninstall() {
    local purge="false"
    for arg in "$@"; do
        case "$arg" in
            --purge|-p|purge) purge="true" ;;
            -y|--yes) ASSUME_YES="true" ;;
        esac
    done

    printf "\n  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_YELLOW" "$C_RESET"
    printf "  %b│%b  %b🗑️  NINE-STACK UNINSTALLER%b                                           %b│%b\n" "$C_YELLOW" "$C_RESET" "$C_BOLD$C_WHITE" "$C_RESET" "$C_YELLOW" "$C_RESET"
    printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n" "$C_YELLOW" "$C_RESET"

    if [[ "${ASSUME_YES:-false}" != "true" ]]; then
        tui_select "Select Uninstallation Mode" \
            "Standard Uninstall — Stop & remove containers/CLI, but KEEP databases, SSL certs & configs" \
            "Complete Purge     — Delete EVERYTHING (containers, volumes, databases, SSL certs & $STACK_DIR)" \
            "Cancel             — Return without uninstalling" || return 0

        case "$TUI_CHOICE" in
            0) purge="false" ;;
            1)
                purge="true"
                warn "Complete Purge will permanently delete all 9Router data and SSL certificates!"
                if ! tui_confirm "Are you 100% sure you want to permanently delete all data?" "n"; then
                    info "Uninstallation canceled."
                    return 0
                fi
                ;;
            *)
                info "Uninstallation canceled."
                return 0
                ;;
        esac
    fi

    # Collect candidate stack and script directories
    local script_dir
    script_dir="$(dirname "$SCRIPT_PATH")"
    local candidate_dirs=("$STACK_DIR" "/opt/nine-stack" "/opt/ai-stack" "/opt/hermes-stack" "${HOME}/nine-stack" "${HOME}/ai-stack" "${HOME}/.hermes-stack")
    # Only include script_dir if it's an installed location (not a git repository checkout)
    if [[ ! -d "$script_dir/.git" ]]; then
        candidate_dirs+=("$script_dir")
    fi

    # 1. Stop and remove containers
    local d
    for d in "${candidate_dirs[@]}"; do
        if [[ -f "$d/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
            info "Stopping containers in $d..."
            if [[ "$purge" == "true" ]]; then
                docker compose -f "$d/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
            else
                docker compose -f "$d/docker-compose.yml" down --remove-orphans 2>/dev/null || true
            fi
        fi
    done

    if command -v docker >/dev/null 2>&1; then
        docker rm -f ai-stack-nine-router ai-stack-caddy ai-stack-xray ai-stack-hermes 2>/dev/null || true
        if [[ "$purge" == "true" ]]; then
            info "Removing Docker persistent volumes..."
            docker volume rm -f ai-stack_nine_router_data ai-stack_caddy_data ai-stack_caddy_config 2>/dev/null || true
        fi
    fi

    # 2. Remove automated backup cron jobs
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "backup create" | grep -v "aistack" | grep -v "ninestack" | grep -v "hermes-stack" || true) | crontab - 2>/dev/null || true
    fi

    # 3. Remove CLI symlinks
    info "Removing CLI shortcuts (aistack, ninestack, hermesstack)..."
    rm -f /usr/local/bin/aistack /usr/local/bin/ninestack /usr/local/bin/hermesstack \
          "${HOME}/.local/bin/aistack" "${HOME}/.local/bin/ninestack" "${HOME}/.local/bin/hermesstack" 2>/dev/null || true

    # 4. Purge or preserve directories
    if [[ "$purge" == "true" ]]; then
        for d in "${candidate_dirs[@]}"; do
            if [[ -d "$d" ]] && [[ ! -d "$d/.git" ]]; then
                info "Removing directory: $d"
                rm -rf "$d" 2>/dev/null || true
            fi
        done
        success "NineStack and all associated data have been completely purged."
    else
        info "Preserved stack data and configurations at: $STACK_DIR"
        success "NineStack containers stopped and CLI shortcuts removed."
    fi
    exit 0
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
    
    # Test 3: Caddyfile generation & 9Router reverse proxy routing
    cat > "$test_dir/domains.tsv" << 'EOF'
test.example.com	9router	auto		
EOF
    generate_caddyfile
    grep -q 'test.example.com {' "$test_dir/Caddyfile" || die "Self-test failed: Caddyfile missing domain block"
    grep -q 'reverse_proxy nine-router:20128' "$test_dir/Caddyfile" || die "Self-test failed: Caddyfile proxy target"
    success "Self-test 3 (Caddyfile generation): PASSED"

    # Test 4: Compose file generation (no hermes container)
    generate_docker_compose
    grep -q 'container_name: ai-stack-nine-router' "$test_dir/docker-compose.yml" || die "Self-test failed: 9Router service missing"
    grep -q 'container_name: ai-stack-hermes' "$test_dir/docker-compose.yml" && die "Self-test failed: Hermes container unexpectedly present"
    success "Self-test 4 (Compose generation without Hermes container): PASSED"
    
    # Cleanup
    STACK_DIR="$prev_stack"
    rm -rf "$test_dir"
    success "All self-tests passed successfully."
}

# Interactive Submenus & Main TUI Loop
tui_menu_domains() {
    while true; do
        domain_list
        tui_select "🌐 Domain & SSL Manager (1-4 quick-pick, q back)" \
            "➕ Add or Update a Domain (Guided Service & SSL Setup)" \
            "🗑️  Remove an Existing Domain" \
            "📖 View Domain Routing & SSL Mode Guide (When to use Auto vs Origin)" \
            "🔄 Regenerate & Reload Caddy Reverse Proxy Now" \
            "🔙 Back to Main Menu" || break
        case "$TUI_CHOICE" in
            0) domain_add "" "" "" || true ;;
            1) domain_rm "" || true ;;
            2) domain_explain_guide; tui_pause ;;
            3) generate_caddyfile; caddy_reload || true; tui_pause ;;
            4) break ;;
        esac
    done
}

tui_menu_proxy() {
    while true; do
        printf "\n"
        proxy_status
        tui_select "🛡️ Outbound Proxy & Xray Anti-Censorship (Routes Containers + Host)" \
            "➕ Import Xray Share Link (vless://, vmess://, trojan://, ss://)" \
            "🔗 Set External SOCKS5 / HTTP Proxy URL (e.g. socks5://127.0.0.1:1080)" \
            "🟢 Enable Outbound Proxy Routing & Apply to Stack" \
            "⚪ Disable Outbound Proxy Routing (Direct Connection)" \
            "🧹 Clear All Imported Xray Share Links" \
            "💻 Show Host Shell Proxy Export Commands (HTTP_PROXY / ALL_PROXY)" \
            "🔙 Back to Main Menu" || break
        case "$TUI_CHOICE" in
            0)
                if proxy_add_link ""; then
                    if tui_confirm "Restart stack now to route traffic through updated Xray balancer?" "y"; then
                        stack_restart
                    fi
                fi
                ;;
            1)
                if proxy_set_external ""; then
                    if tui_confirm "Restart stack now to apply external proxy?" "y"; then
                        stack_restart
                    fi
                fi
                ;;
            2) proxy_enable && stack_restart ;;
            3) proxy_disable && stack_restart ;;
            4)
                if tui_confirm "Clear all imported Xray share links?" "n"; then
                    proxy_clear_links
                fi
                ;;
            5)
                printf "\n"
                proxy_env || true
                tui_pause
                ;;
            6) break ;;
        esac
    done
}

tui_menu_features() {
    local dirty=0
    while true; do
        local c_en
        c_en=$(env_get "CADDY_ENABLED" "auto")
        local m_cap
        m_cap=$(env_get "NINE_ROUTER_MAX_MEM" "256")
        local req_key
        req_key=$(env_get "REQUIRE_API_KEY" "false")

        tui_select "🪶 Tuning, Caddy & Auth Settings (Press Enter to toggle)" \
            "Caddy Reverse Proxy : [${c_en}] → Press to cycle (auto = only runs when domains exist)" \
            "9Router V8 Heap Cap : ${m_cap} MB → Press to change (192MB / 256MB / 512MB / Custom)" \
            "API Key Enforcement : $([[ "$req_key" == "true" ]] && echo "ON  → Strict keys only (Press to allow sk_9router)" || echo "OFF → Permissive sk_9router (Press to enforce keys)")" \
            "✅ Apply Changes & Restart Stack Now" \
            "🔙 Back to Main Menu" || break

        case "$TUI_CHOICE" in
            0)
                case "$c_en" in
                    auto)  features_set caddy on ;;
                    true)  features_set caddy off ;;
                    *)     features_set caddy auto ;;
                esac
                dirty=1
                ;;
            1)
                tui_select "Select 9Router V8 Max Memory Limit" \
                    "192 MB — Ultra-Light (For 1GB–2GB RAM VPS)" \
                    "256 MB — Balanced Default (Recommended)" \
                    "512 MB — High Concurrency (For 4GB+ RAM VPS)" \
                    "Custom MB Value" || continue
                case "$TUI_CHOICE" in
                    0) features_set memory 192 ;;
                    1) features_set memory 256 ;;
                    2) features_set memory 512 ;;
                    3)
                        local custom_m=""
                        tui_input "Enter max memory in MB (min 128)" "$m_cap" custom_m
                        features_set memory "$custom_m" || true
                        ;;
                esac
                dirty=1
                ;;
            2)
                [[ "$req_key" == "true" ]] && features_set require-key off || features_set require-key on
                dirty=1
                ;;
            3)
                stack_restart
                dirty=0
                ;;
            4)
                if (( dirty == 1 )); then
                    if tui_confirm "Apply feature changes and restart stack now?" "y"; then
                        stack_restart
                    fi
                fi
                break
                ;;
        esac
    done
}

tui_menu_maintenance() {
    while true; do
        tui_select "🧰 Backups, Updates, Iran Toolkit & Maintenance" \
            "💾 Backup & Restore Manager (SQLite + SSL + Configs)" \
            "🇮🇷 Iran VPS Resilience Toolkit (Docker Mirrors / MTU / Offline Bundles)" \
            "🔄 Update Stack Container Images (With Auto-Backup & Rollback)" \
            "⏪ Rollback Stack Images to Previous Digests" \
            "📜 Stream Live Container Logs (All or Per-Service)" \
            "🚀 Re-run Initial Guided Setup Wizard" \
            "🔙 Back to Main Menu" || break
        case "$TUI_CHOICE" in
            0) tui_menu_backups ;;
            1) tui_menu_iran ;;
            2) stack_update; tui_pause ;;
            3) stack_rollback; tui_pause ;;
            4) tui_menu_logs ;;
            5) stack_setup; tui_pause ;;
            6) break ;;
        esac
    done
}

tui_menu_backups() {
    while true; do
        backup_list
        tui_select "Backup & Restore Manager" \
            "Create New Full Backup Archive (SQLite + SSL + Config)" \
            "Restore Stack from a Backup Archive" \
            "Enable Daily Automated Backup Cron (03:00 AM)" \
            "Back to Main Menu" || break
        case "$TUI_CHOICE" in
            0)
                local tag=""
                tui_input "Backup label" "manual" tag
                backup_create "$tag"
                tui_pause
                ;;
            1)
                local b_files=()
                local f
                for f in "$STACK_DIR"/backups/backup-*.tar.gz; do
                    [[ -f "$f" ]] && b_files+=("$(basename "$f") ($(du -h "$f" | cut -f1))")
                done
                if [[ ${#b_files[@]} -eq 0 ]]; then
                    warn "No backup archives found in $STACK_DIR/backups."
                else
                    if tui_select "Select backup archive to restore" "${b_files[@]}"; then
                        local chosen_file="$STACK_DIR/backups/${b_files[$TUI_CHOICE]%% *}"
                        backup_restore "$chosen_file"
                    fi
                fi
                ;;
            2)
                install_backup_cron
                tui_pause
                ;;
            3) break ;;
        esac
    done
}

tui_menu_iran() {
    while true; do
        tui_select "Iran VPS Network Resilience Toolkit" \
            "Detect Network Restrictions & DNS Poisoning" \
            "Benchmark & Configure Iranian Docker Mirrors" \
            "Tune Docker MTU (1400) to Prevent TLS Packet Drops" \
            "Export Offline Container Image Bundle (.tar.gz)" \
            "Import Offline Container Image Bundle (.tar.gz)" \
            "Back to Main Menu" || break
        case "$TUI_CHOICE" in
            0)
                if detect_iran_network; then
                    warn "Host is affected by Iranian network restrictions or DNS poisoning."
                else
                    success "Host has direct international network connectivity."
                fi
                tui_pause
                ;;
            1) configure_docker_mirrors || true; tui_pause ;;
            2)
                local mtu_val=""
                tui_input "Docker MTU value" "1400" mtu_val
                configure_docker_mtu "$mtu_val" || true
                tui_pause
                ;;
            3)
                local exp_file=""
                tui_input "Output bundle path" "$STACK_DIR/ai-stack-images.tar.gz" exp_file
                bundle_export "$exp_file"
                tui_pause
                ;;
            4)
                local imp_file=""
                tui_input "Path to bundle .tar.gz file" "$STACK_DIR/ai-stack-images.tar.gz" imp_file
                bundle_import "$imp_file" || true
                tui_pause
                ;;
            5) break ;;
        esac
    done
}

tui_menu_logs() {
    tui_select "Select Service Logs to Stream (Press Ctrl+C to stop streaming)" \
        "All Services" \
        "9Router (AI Gateway)" \
        "Caddy Reverse Proxy" \
        "Xray Proxy Balancer" \
        "Back to Main Menu" || return 0
    case "$TUI_CHOICE" in
        0) stack_logs "" || true ;;
        1) stack_logs "nine-router" || true ;;
        2) stack_logs "caddy" || true ;;
        3) stack_logs "xray" || true ;;
        4) return 0 ;;
    esac
}

tui_menu_clients() {
    while true; do
        local rpass
        rpass=$(env_get "INITIAL_PASSWORD" "123456")
        local req_key
        req_key=$(env_get "REQUIRE_API_KEY" "false")

        tui_select "🔌 Connect External AI Clients (Hermes, Cursor, Cline, Claude Code)" \
            "📖 View Comprehensive Client Setup Guide & cURL Examples" \
            "🔑 Change 9Router Initial Admin Password (Current: $rpass)" \
            "🛡️  Toggle API Key Enforcement (Currently: $([[ "$req_key" == "true" ]] && echo "Enforced" || echo "Permissive - sk_9router"))" \
            "💻 Show Host Shell Proxy Export Commands (HTTP_PROXY / ALL_PROXY)" \
            "Back to Main Menu" || break

        case "$TUI_CHOICE" in
            0) client_access_info; tui_pause ;;
            1)
                local new_pass=""
                tui_input "Enter new 9Router admin password" "$rpass" new_pass
                if [[ -n "$new_pass" ]]; then
                    env_set "INITIAL_PASSWORD" "$new_pass"
                    generate_docker_compose
                    success "9Router password updated. Restart stack to apply."
                fi
                ;;
            2)
                [[ "$req_key" == "true" ]] && features_set require-key off || features_set require-key on
                tui_pause
                ;;
            3)
                printf "\n"
                proxy_env || true
                tui_pause
                ;;
            4) break ;;
        esac
    done
}

interactive_menu() {
    local last_choice=0
    while true; do
        tui_header
        TUI_DEFAULT_INDEX="$last_choice" tui_select "Main Menu (Keys 1-9 instant select)" \
            "🔌 Connect AI Clients    — Guides & Configs for Hermes, Cursor, Cline, Claude Code" \
            "🌐 Domain & SSL Manager  — Expose 9Router via Auto-TLS or Cloudflare/Arvan CDN" \
            "🛡️ Proxy & Xray Routing  — VLESS/VMess/Trojan/SS Balancer & Host Proxy" \
            "🪶 Tuning & Features     — Caddy Mode, 9Router V8 Heap Cap, API Key Auth" \
            "📊 Status & Diagnostics — Container Health, Ports, Passwords & System Doctor" \
            "⚡ Lifecycle & Logs      — Start, Stop, Restart Services & Stream Logs" \
            "🧰 Maintenance & Backups — Backups, Iran Mirrors/MTU, Image Updates & Offline Bundles" \
            "🗑️  Uninstall Stack       — Stop Stack & Remove CLI (Keep or Purge Data)" \
            "🚪 Exit" || break

        last_choice=$TUI_CHOICE
        case "$TUI_CHOICE" in
            0) tui_menu_clients ;;
            1) tui_menu_domains ;;
            2) tui_menu_proxy ;;
            3) tui_menu_features ;;
            4) stack_status; client_access_info; tui_pause ;;
            5)
                tui_select "⚡ Service Lifecycle & Diagnostics" \
                    "🔄 Start / Restart All Stack Services" \
                    "🛑 Stop All Stack Services" \
                    "🩺 Run System & Outbound Network Doctor" \
                    "📜 Stream Live Container Logs" \
                    "🔙 Back to Main Menu" || continue
                case "$TUI_CHOICE" in
                    0) stack_restart; tui_pause ;;
                    1) stack_stop; tui_pause ;;
                    2) stack_doctor; tui_pause ;;
                    3) tui_menu_logs ;;
                esac
                ;;
            6) tui_menu_maintenance ;;
            7) stack_uninstall ;;
            8) break ;;
        esac
    done
    printf "\n"
}

# ------------------------------------------------------------------------------
# CLI Dispatcher
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF
AI Stack Manager v${VERSION}
Manage 9Router (LLM Gateway), Caddy (Domains & Auto-TLS), and Xray (Anti-Censorship).

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

AI Clients & Access:
  clients / access      Show manual client configs (Hermes Agent, Cursor, Cline, cURL)
  hermes [args...]      Show client setup instructions for Hermes Agent

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

Feature & Resource Tuning:
  features status                Show Caddy mode, memory cap, and auth settings
  features caddy <auto|on|off>   Set Caddy mode (auto = only runs when domains exist)
  features memory <MB>           Set 9Router V8 max memory limit in MB (default: 256)
  features require-key <on|off>  Toggle strict API key enforcement

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
  uninstall [--purge]   Uninstall NineStack (optionally purge all data & volumes)
  shortcut              Install 'aistack' & 'ninestack' CLI shortcuts
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
    if [[ -t 0 ]] || is_interactive_tty; then
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
    menu|tui)
        interactive_menu
        ;;
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
            caddy|memory|auth|require-key|require_key) features_set "$sub" "${1:-}" ;;
            *) die "Unknown features subcommand: $sub" ;;
        esac
        ;;
    clients|access)
        client_access_info
        ;;
    hermes|agent|chat)
        hermes_cli "$@"
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
    uninstall|remove)
        stack_uninstall "$@"
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
