#!/usr/bin/env bash
# ==============================================================================
# Standalone Hermes Agent Docker Manager
# Runs Nous Hermes Agent in Docker with full manual control over model,
# gateway URL, API keys, integrations, and daemon lifecycle.
# ==============================================================================
set -Eeuo pipefail

HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:latest}"
HERMES_CONTAINER="${HERMES_CONTAINER:-hermes-agent}"
HERMES_DATA_DIR="${HERMES_DATA_DIR:-${HOME}/.hermes-agent}"

# Formatting
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_CYAN="\033[36m"
    C_RED="\033[31m"
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    C_RED=""
fi

info()    { printf "%bℹ%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
success() { printf "%b✔%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf "%b⚠%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf "%b✖%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

ensure_dirs() {
    mkdir -p "$HERMES_DATA_DIR"
    chmod 755 "$HERMES_DATA_DIR"
}

# Generate or update config.yaml
get_config_val() {
    local key="$1"
    local default_val="${2:-}"
    local cfg="$HERMES_DATA_DIR/config.yaml"
    [[ ! -f "$cfg" ]] && { echo "$default_val"; return; }
    python3 -c "
import sys, yaml
try:
    with open('$cfg', 'r') as f:
        data = yaml.safe_load(f) or {}
    keys = '$key'.split('.')
    val = data
    for k in keys:
        val = val.get(k, {})
    if isinstance(val, (str, int, float, bool)):
        print(val)
    else:
        print('$default_val')
except Exception:
    print('$default_val')
" 2>/dev/null || echo "$default_val"
}

set_config_val() {
    local key="$1"
    local val="$2"
    local cfg="$HERMES_DATA_DIR/config.yaml"
    ensure_dirs
    python3 -c "
import sys, os, yaml

cfg_path = '$cfg'
data = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        data = {}

keys = '$key'.split('.')
d = data
for k in keys[:-1]:
    if k not in d or not isinstance(d[k], dict):
        d[k] = {}
    d = d[k]

v = '$val'
if v.lower() == 'true':
    v = True
elif v.lower() == 'false':
    v = False
elif v.isdigit():
    v = int(v)

d[keys[-1]] = v

with open(cfg_path, 'w', encoding='utf-8') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
"
}

ensure_init_config() {
    ensure_dirs
    local cfg="$HERMES_DATA_DIR/config.yaml"
    if [[ ! -f "$cfg" ]]; then
        cat > "$cfg" << 'EOF'
model:
  default: "gpt-4o"
  provider: custom
  base_url: "http://127.0.0.1:20128/v1"
  api_key: "sk_9router"
dashboard:
  enabled: true
  port: 9119
api:
  enabled: true
  port: 8642
EOF
        chmod 600 "$cfg"
        success "Initialized default config at: $cfg"
    fi
}

# Run container commands
docker_exec() {
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
        die "Container '${HERMES_CONTAINER}' is not running. Start it with: $(basename "$0") start"
    fi
    if [[ -t 0 ]] && [[ -t 1 ]]; then
        docker exec -it "$HERMES_CONTAINER" "$@"
    else
        docker exec -i "$HERMES_CONTAINER" "$@"
    fi
}

# Command: Setup / Wizard
cmd_setup() {
    ensure_init_config
    local cur_gw cur_key cur_model
    cur_gw=$(get_config_val "model.base_url" "http://127.0.0.1:20128/v1")
    cur_key=$(get_config_val "model.api_key" "sk_9router")
    cur_model=$(get_config_val "model.default" "gpt-4o")

    printf "\n%b=== Hermes Agent Docker Setup ===%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    
    read -r -p "Gateway Base URL [${cur_gw}]: " in_gw || in_gw=""
    in_gw="${in_gw:-$cur_gw}"
    set_config_val "model.base_url" "$in_gw"
    set_config_val "model.provider" "custom"

    read -r -p "Gateway API Key [${cur_key}]: " in_key || in_key=""
    in_key="${in_key:-$cur_key}"
    set_config_val "model.api_key" "$in_key"

    read -r -p "Default Model [${cur_model}]: " in_model || in_model=""
    in_model="${in_model:-$cur_model}"
    set_config_val "model.default" "$in_model"

    success "Config saved to $HERMES_DATA_DIR/config.yaml"
    info "Model:    $in_model"
    info "Gateway:  $in_gw"
    info "API Key:  $in_key"
    printf "\n"
    read -r -p "Start Hermes daemon container now? [Y/n]: " start_now || start_now="y"
    if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
        cmd_start
    fi
}

# Command: Start background daemon
cmd_start() {
    ensure_init_config
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
        info "Container '${HERMES_CONTAINER}' is already running."
        return 0
    fi
    docker rm -f "$HERMES_CONTAINER" 2>/dev/null || true

    info "Starting '${HERMES_CONTAINER}' using image ${HERMES_IMAGE}..."

    # Detect network mode:
    # On Linux host network allows direct 127.0.0.1:20128 access to 9Router on host
    local net_flags=("--network=host")
    if [[ "$(uname -s)" != "Linux" ]]; then
        net_flags=("-p" "9119:9119" "-p" "8642:8642" "--add-host=host.docker.internal:host-gateway")
    fi

    # Check if stack outbound proxy exists
    local proxy_envs=()
    if curl -s --connect-timeout 1 http://127.0.0.1:10809 >/dev/null 2>&1; then
        info "Detected active outbound HTTP proxy on 127.0.0.1:10809. Attaching proxy environment..."
        proxy_envs+=(
            "-e" "HTTP_PROXY=http://127.0.0.1:10809"
            "-e" "HTTPS_PROXY=http://127.0.0.1:10809"
            "-e" "ALL_PROXY=socks5://127.0.0.1:10808"
            "-e" "NO_PROXY=localhost,127.0.0.1,nine-router,caddy"
        )
    fi

    docker run -d \
        --name "$HERMES_CONTAINER" \
        --restart unless-stopped \
        "${net_flags[@]}" \
        -v "$HERMES_DATA_DIR:/opt/data" \
        -e "PYTHONDONTWRITEBYTECODE=1" \
        -e "PYTHONUNBUFFERED=1" \
        -e "HERMES_DASHBOARD=1" \
        -e "API_SERVER_ENABLED=true" \
        -e "API_SERVER_HOST=0.0.0.0" \
        "${proxy_envs[@]}" \
        "$HERMES_IMAGE" \
        gateway run >/dev/null

    sleep 2
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
        success "Hermes Agent started successfully!"
        info "Web UI:   http://localhost:9119"
        info "API:      http://localhost:8642"
        info "Model:    $(get_config_val "model.default" "unknown")"
        info "Gateway:  $(get_config_val "model.base_url" "unknown")"
        info "Run chat: $(basename "$0") chat"
    else
        die "Failed to start Hermes Agent container. Check logs: docker logs $HERMES_CONTAINER"
    fi
}

cmd_stop() {
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
        info "Stopping container '${HERMES_CONTAINER}'..."
        docker stop "$HERMES_CONTAINER" >/dev/null 2>&1 || true
        docker rm -f "$HERMES_CONTAINER" >/dev/null 2>&1 || true
        success "Hermes Agent container stopped."
    else
        info "Container '${HERMES_CONTAINER}' is not running."
    fi
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_chat() {
    ensure_init_config
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
        cmd_start
    fi
    docker_exec hermes chat "$@"
}

cmd_tui() {
    ensure_init_config
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
        cmd_start
    fi
    docker_exec hermes --tui "$@"
}

cmd_model() {
    ensure_init_config
    if [[ $# -gt 0 ]]; then
        set_config_val "model.default" "$1"
        success "Hermes model set to: $1"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
            cmd_restart
        fi
    else
        local m
        m=$(get_config_val "model.default" "not set")
        printf "%bCurrent Model:%b %s\n" "$C_BOLD" "$C_RESET" "$m"
        info "To change: $(basename "$0") model <new-model-name>"
    fi
}

cmd_gateway() {
    ensure_init_config
    if [[ $# -gt 0 ]]; then
        set_config_val "model.base_url" "$1"
        set_config_val "model.provider" "custom"
        if [[ $# -gt 1 ]]; then
            set_config_val "model.api_key" "$2"
        fi
        success "Gateway updated to: $1"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
            cmd_restart
        fi
    else
        local gw key
        gw=$(get_config_val "model.base_url" "not set")
        key=$(get_config_val "model.api_key" "not set")
        printf "%bCurrent Gateway URL:%b %s\n" "$C_BOLD" "$C_RESET" "$gw"
        printf "%bCurrent API Key:%b     %s\n" "$C_BOLD" "$C_RESET" "$key"
        info "To change: $(basename "$0") gateway <url> [api_key]"
    fi
}

cmd_status() {
    printf "\n%b=== Hermes Agent Status ===%b\n" "$C_BOLD$C_CYAN" "$C_RESET"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
        printf "Container: %bRunning%b (%s)\n" "$C_GREEN" "$C_RESET" "$HERMES_CONTAINER"
    else
        printf "Container: %bStopped%b\n" "$C_YELLOW" "$C_RESET"
    fi
    printf "Data Dir:  %s\n" "$HERMES_DATA_DIR"
    printf "Config:    %s/config.yaml\n" "$HERMES_DATA_DIR"
    printf "Model:     %s\n" "$(get_config_val "model.default" "not set")"
    printf "Gateway:   %s\n" "$(get_config_val "model.base_url" "not set")"
    printf "API Key:   %s\n" "$(get_config_val "model.api_key" "not set")"
    printf "Web UI:    http://localhost:9119\n"
    printf "API:       http://localhost:8642\n\n"
}

cmd_install_shortcut() {
    local target="/usr/local/bin/hermes-docker"
    if [[ "$(id -u)" -ne 0 ]]; then
        target="${HOME}/.local/bin/hermes-docker"
        mkdir -p "${HOME}/.local/bin"
    fi
    local self_path
    self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    ln -sf "$self_path" "$target"
    success "Installed shortcut at: $target"
    info "You can now run 'hermes-docker' from anywhere."
}

show_help() {
    cat << EOF
Hermes Agent Docker Manager
Control and customize Hermes Agent running in Docker.

Usage:
  $(basename "$0") [command] [args...]

Core Commands:
  setup                 Interactive wizard to configure model, gateway, and API key
  start                 Start Hermes Agent daemon container (background)
  stop                  Stop Hermes Agent container
  restart               Restart Hermes Agent container
  status                Show running status, ports, model, and gateway

Interactions:
  chat [args...]        Launch interactive chat session in terminal
  tui                   Launch full terminal user interface
  exec [cmd...]         Run command inside running container
  shell / bash          Open interactive bash shell inside container
  logs [-f]             View or follow container logs

Configuration:
  model [name]          Show or change default model (e.g. gpt-4o, claude-3-5-sonnet)
  gateway [url] [key]   Show or set OpenAI gateway URL and API key
  config show           Display current config.yaml
  config edit           Open config.yaml in \$EDITOR

System:
  shortcut              Create 'hermes-docker' global CLI shortcut in PATH
  pull                  Pull latest hermes-agent docker image
EOF
}

# Subcommand router
SUBCMD="${1:-}"
shift || true

case "$SUBCMD" in
    setup|init)
        cmd_setup "$@"
        ;;
    start|up)
        cmd_start "$@"
        ;;
    stop|down)
        cmd_stop "$@"
        ;;
    restart)
        cmd_restart "$@"
        ;;
    status|info)
        cmd_status "$@"
        ;;
    chat)
        cmd_chat "$@"
        ;;
    tui)
        cmd_tui "$@"
        ;;
    model)
        cmd_model "$@"
        ;;
    gateway|gw)
        cmd_gateway "$@"
        ;;
    config)
        sub="${1:-show}"
        shift || true
        case "$sub" in
            edit)
                ensure_init_config
                "${EDITOR:-nano}" "$HERMES_DATA_DIR/config.yaml"
                ;;
            show|cat)
                ensure_init_config
                cat "$HERMES_DATA_DIR/config.yaml"
                ;;
            *)
                die "Usage: $(basename "$0") config <show|edit>"
                ;;
        esac
        ;;
    shell|bash|sh)
        docker_exec bash "$@"
        ;;
    exec)
        docker_exec "$@"
        ;;
    logs)
        docker logs "${@:--f}" "$HERMES_CONTAINER"
        ;;
    pull)
        info "Pulling $HERMES_IMAGE..."
        docker pull "$HERMES_IMAGE"
        success "Image updated."
        ;;
    shortcut|install-shortcut)
        cmd_install_shortcut
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        # Passthrough any native hermes command directly into the container
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${HERMES_CONTAINER}$"; then
            docker_exec hermes "$SUBCMD" "$@"
        else
            show_help
            exit 1
        fi
        ;;
esac
