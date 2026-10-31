#!/usr/bin/env bash
# ==============================================================================
# HermesStack One-Liner Installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/IHosseini083/HermesStack/main/install.sh | bash
# ==============================================================================
set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/IHosseini083/HermesStack/main"

# Color helpers
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_CYAN="\033[36m"
    C_RED="\033[31m"
else
    C_RESET=""
    C_BOLD=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    C_RED=""
fi

info()    { printf "%b[INFO]%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
success() { printf "%b[OK]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf "%b[ERROR]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

printf "\n%b=== HermesStack Installer ===%b\n\n" "$C_BOLD" "$C_RESET"

# Check root or user
if [[ "$(id -u)" -eq 0 ]]; then
    INSTALL_DIR="/opt/hermes-stack"
    BIN_DIR="/usr/local/bin"
else
    INSTALL_DIR="${HOME}/.hermes-stack"
    BIN_DIR="${HOME}/.local/bin"
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# Download manage.sh
info "Downloading HermesStack CLI to $INSTALL_DIR/manage.sh..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${REPO_RAW}/manage.sh" -o "$INSTALL_DIR/manage.sh"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$INSTALL_DIR/manage.sh" "${REPO_RAW}/manage.sh"
else
    die "Neither curl nor wget is available."
fi

chmod +x "$INSTALL_DIR/manage.sh"

# Install symlink
ln -sf "$INSTALL_DIR/manage.sh" "$BIN_DIR/aistack"
ln -sf "$INSTALL_DIR/manage.sh" "$BIN_DIR/hermesstack" 2>/dev/null || true

# Verify PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not in your current PATH. Add it to ~/.bashrc: export PATH=\"\$PATH:$BIN_DIR\""
fi

success "HermesStack installed successfully at $INSTALL_DIR"
success "Command available as: aistack (or hermesstack)"

# Check if unattended flag passed
if [[ "${1:-}" == "--no-start" ]]; then
    info "Installation complete. Run 'aistack setup' when ready."
    exit 0
fi

if [[ -t 0 ]]; then
    info "Launching setup wizard..."
    exec "$BIN_DIR/aistack" setup
elif [[ -t 1 ]] && [[ -e /dev/tty ]]; then
    info "Launching setup wizard..."
    exec "$BIN_DIR/aistack" setup </dev/tty
else
    info "Non-interactive shell detected. Run 'aistack setup' to initialize."
fi
