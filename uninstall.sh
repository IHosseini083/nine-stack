#!/usr/bin/env bash
# ==============================================================================
# HermesStack One-Liner Uninstaller
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/IHosseini083/HermesStack/main/uninstall.sh | bash
# ==============================================================================
set -Eeuo pipefail

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

info()    { printf "%b  ℹ %b%s\n" "$C_CYAN" "$C_RESET" "$*"; }
success() { printf "%b  ✔ %b%s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf "%b  ⚠ %b%s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf "%b  ✖ %b%s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

PURGE=false
ASSUME_YES=false

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=true ;;
        -y|--yes) ASSUME_YES=true ;;
    esac
done

printf "\n"
printf "  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_YELLOW" "$C_RESET"
printf "  %b│%b  %b🗑️  HERMES STACK UNINSTALLER%b                                         %b│%b\n" "$C_YELLOW" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_YELLOW" "$C_RESET"
printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n\n" "$C_YELLOW" "$C_RESET"

# Detect install locations
TARGET_DIRS=("/opt/hermes-stack" "/opt/ai-stack" "${HOME}/.hermes-stack" "${HOME}/ai-stack")
STACK_DIRS=()
for d in "${TARGET_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
        STACK_DIRS+=("$d")
    fi
done

if [[ ${#STACK_DIRS[@]} -eq 0 ]]; then
    warn "No HermesStack installation directory found."
fi

if [[ "$ASSUME_YES" != "true" ]]; then
    printf "%bThis will stop and remove all HermesStack containers.%b\n" "$C_YELLOW" "$C_RESET"
    if [[ "$PURGE" == "true" ]]; then
        printf "%bWARNING: --purge flag specified. All databases, certificates, and configs will be deleted!%b\n" "$C_RED" "$C_RESET"
    fi
    if { true </dev/tty; } 2>/dev/null; then
        read -r -p "Do you want to proceed with uninstallation? [y/N]: " confirm </dev/tty || confirm="n"
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            info "Uninstallation canceled."
            exit 0
        fi
        if [[ "$PURGE" != "true" ]]; then
            read -r -p "Also purge all persistent data, configs, and SSL certificates? [y/N]: " purge_confirm </dev/tty || purge_confirm="n"
            if [[ "$purge_confirm" == "y" || "$purge_confirm" == "Y" ]]; then
                PURGE=true
            fi
        fi
    else
        die "Non-interactive shell without TTY. Pass '-y' (e.g. 'curl ... | bash -s -- -y') to confirm."
    fi
fi

# 1. Stop and remove containers
for d in "${STACK_DIRS[@]}"; do
    if [[ -f "$d/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
        info "Stopping containers in $d..."
        if [[ "$PURGE" == "true" ]]; then
            docker compose -f "$d/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
        else
            docker compose -f "$d/docker-compose.yml" down --remove-orphans 2>/dev/null || true
        fi
    fi
done

# 2. Remove Docker volumes if purged
if [[ "$PURGE" == "true" ]] && command -v docker >/dev/null 2>&1; then
    info "Removing Docker persistent volumes..."
    docker volume rm -f ai-stack_nine_router_data ai-stack_caddy_data ai-stack_caddy_config 2>/dev/null || true
fi

# 3. Remove cron jobs
info "Removing automated backup cron jobs..."
crontab -l 2>/dev/null | grep -v "aistack backup" | grep -v "hermes-stack" | crontab - 2>/dev/null || true

# 4. Remove binaries and symlinks
info "Removing CLI symlinks..."
rm -f /usr/local/bin/aistack /usr/local/bin/hermesstack 2>/dev/null || true
rm -f "${HOME}/.local/bin/aistack" "${HOME}/.local/bin/hermesstack" 2>/dev/null || true

# 5. Remove or keep directory
if [[ "$PURGE" == "true" ]]; then
    for d in "${STACK_DIRS[@]}"; do
        info "Removing installation directory $d..."
        rm -rf "$d"
    done
    success "HermesStack and all associated data completely purged."
else
    for d in "${STACK_DIRS[@]}"; do
        info "Preserved data directory: $d (Pass --purge to delete it)"
    done
    success "HermesStack stopped and CLI removed. Configuration files preserved."
fi
