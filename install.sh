#!/usr/bin/env bash
# ==============================================================================
# NineStack One-Liner Installer & Updater
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/IHosseini083/nine-stack/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/IHosseini083/nine-stack/main/install.sh | bash -s -- --no-start
#   curl -fsSL https://raw.githubusercontent.com/IHosseini083/nine-stack/main/install.sh | bash -s -- --update
# ==============================================================================
set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/IHosseini083/nine-stack/main"

# Color helpers
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
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

info()    { printf "%b  ℹ %b%s\n" "$C_CYAN" "$C_RESET" "$*"; }
success() { printf "%b  ✔ %b%s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf "%b  ⚠ %b%s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf "%b  ✖ %b%s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

NO_START=false
UPDATE_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --no-start) NO_START=true ;;
        --update|-u) UPDATE_ONLY=true ;;
    esac
done

printf "\n"
printf "  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_CYAN" "$C_RESET"
printf "  %b│%b  %b⚡ NINE-STACK INSTALLER & UPDATER%b                                  %b│%b\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
printf "  %b│%b  9Router LLM Gateway • Caddy Auto-TLS • Xray Anti-Censorship      %b│%b\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n\n" "$C_CYAN" "$C_RESET"

# Determine unified stack directory (single source of truth for CLI + data)
if [[ "$(id -u)" -eq 0 ]]; then
    INSTALL_DIR="${STACK_DIR:-/opt/nine-stack}"
    BIN_DIR="/usr/local/bin"
else
    INSTALL_DIR="${STACK_DIR:-${HOME}/nine-stack}"
    BIN_DIR="${HOME}/.local/bin"
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# Download manage.sh atomically and verify syntax before replacing
TMP_SCRIPT="$(mktemp -p /tmp aistack-install-XXXXXX)"
cleanup_tmp() { rm -f "$TMP_SCRIPT" 2>/dev/null || true; }
trap cleanup_tmp EXIT

info "Downloading NineStack Manager to $INSTALL_DIR/manage.sh..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 "${REPO_RAW}/manage.sh" -o "$TMP_SCRIPT"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_SCRIPT" "${REPO_RAW}/manage.sh"
else
    die "Neither curl nor wget is available on this system."
fi

if ! bash -n "$TMP_SCRIPT" 2>/dev/null; then
    die "Downloaded manage.sh failed syntax verification (incomplete download or network MITM)."
fi

mv -f "$TMP_SCRIPT" "$INSTALL_DIR/manage.sh"
chmod +x "$INSTALL_DIR/manage.sh"

# Clean up legacy duplicate script directory if present
for legacy_dir in "/opt/ai-stack" "/opt/hermes-stack" "${HOME}/ai-stack" "${HOME}/.hermes-stack"; do
    if [[ -d "$legacy_dir" ]] && [[ "$legacy_dir" != "$INSTALL_DIR" ]] && [[ ! -f "$legacy_dir/.env" ]]; then
        rm -rf "$legacy_dir" 2>/dev/null || true
    fi
done

# Install CLI symlinks
ln -sf "$INSTALL_DIR/manage.sh" "$BIN_DIR/aistack"
ln -sf "$INSTALL_DIR/manage.sh" "$BIN_DIR/ninestack" 2>/dev/null || true
ln -sf "$INSTALL_DIR/manage.sh" "$BIN_DIR/hermesstack" 2>/dev/null || true

# Verify PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not in your PATH. Add to ~/.bashrc: export PATH=\"\$PATH:$BIN_DIR\""
fi

success "NineStack CLI installed at: $INSTALL_DIR/manage.sh"
success "Global commands ready:        aistack, ninestack (or hermesstack)"

if [[ "$NO_START" == "true" ]] || [[ "$UPDATE_ONLY" == "true" ]]; then
    info "CLI updated. Run 'aistack' to open the interactive TUI or 'aistack setup' to re-run wizard."
    exit 0
fi

# If already configured (.env exists), open TUI or ask whether to re-run setup
if [[ -f "$INSTALL_DIR/.env" ]]; then
    if [[ -t 1 ]] && { true </dev/tty; } 2>/dev/null; then
        info "Existing configuration detected at $INSTALL_DIR/.env. Opening Stack Manager TUI..."
        exec "$BIN_DIR/aistack" </dev/tty
    else
        info "Existing configuration updated. Run 'aistack' to manage your stack."
        exit 0
    fi
fi

if [[ -t 0 ]]; then
    info "Launching guided setup wizard..."
    exec "$BIN_DIR/aistack" setup
elif [[ -t 1 ]] && { true </dev/tty; } 2>/dev/null; then
    info "Launching guided setup wizard..."
    exec "$BIN_DIR/aistack" setup </dev/tty
else
    info "Non-interactive shell detected. Run 'aistack setup' to initialize."
fi
