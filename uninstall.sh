#!/usr/bin/env bash
# ==============================================================================
# HermesStack One-Liner Uninstaller
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/IHosseini083/HermesStack/main/uninstall.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/IHosseini083/HermesStack/main/uninstall.sh | bash -s -- --purge -y
# ==============================================================================
set -Eeuo pipefail

# Delegate to installed 'aistack uninstall' if available so TUI & logic stay unified
if command -v aistack >/dev/null 2>&1; then
    if [[ -t 1 ]] && { true </dev/tty; } 2>/dev/null; then
        exec aistack uninstall "$@" </dev/tty
    else
        exec aistack uninstall "$@"
    fi
fi

# Standalone fallback when 'aistack' binary is already missing
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
        --purge|-p|purge) PURGE=true ;;
        -y|--yes) ASSUME_YES=true ;;
    esac
done

printf "\n"
printf "  %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_YELLOW" "$C_RESET"
printf "  %b│%b  %b🗑️  HERMES STACK UNINSTALLER%b                                         %b│%b\n" "$C_YELLOW" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_YELLOW" "$C_RESET"
printf "  %b╰──────────────────────────────────────────────────────────────────────╯%b\n\n" "$C_YELLOW" "$C_RESET"

TARGET_DIRS=("/opt/ai-stack" "/opt/hermes-stack" "${HOME}/ai-stack" "${HOME}/.hermes-stack")
STACK_DIRS=()
for d in "${TARGET_DIRS[@]}"; do
    [[ -d "$d" ]] && STACK_DIRS+=("$d")
done

if [[ "$ASSUME_YES" != "true" ]]; then
    if { true </dev/tty; } 2>/dev/null; then
        printf "  Select Uninstallation Mode:\n"
        printf "    1) Standard Uninstall — Stop containers & remove CLI, KEEP data & SSL certs\n"
        printf "    2) Complete Purge     — Delete EVERYTHING (containers, volumes, data & configs)\n"
        printf "    3) Cancel\n"
        read -r -p "  Choice [1-3] (default 1): " mode_choice </dev/tty || mode_choice="3"
        case "${mode_choice:-1}" in
            1) PURGE=false ;;
            2)
                read -r -p "  Are you 100% sure you want to permanently delete all data? [y/N]: " confirm_p </dev/tty || confirm_p="n"
                [[ "$confirm_p" =~ ^[Yy]$ ]] || { info "Uninstallation canceled."; exit 0; }
                PURGE=true
                ;;
            *) info "Uninstallation canceled."; exit 0 ;;
        esac
    else
        die "Non-interactive shell without TTY. Pass '-y' (and optionally '--purge') to confirm."
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

if command -v docker >/dev/null 2>&1; then
    docker rm -f ai-stack-nine-router ai-stack-hermes ai-stack-caddy ai-stack-xray 2>/dev/null || true
    if [[ "$PURGE" == "true" ]]; then
        info "Removing Docker persistent volumes..."
        docker volume rm -f ai-stack_nine_router_data ai-stack_caddy_data ai-stack_caddy_config 2>/dev/null || true
    fi
fi

# 2. Remove cron jobs & symlinks
if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "backup create" | grep -v "aistack" | grep -v "hermes-stack" || true) | crontab - 2>/dev/null || true
fi
rm -f /usr/local/bin/aistack /usr/local/bin/hermesstack "${HOME}/.local/bin/aistack" "${HOME}/.local/bin/hermesstack" 2>/dev/null || true

# 3. Remove or preserve directories
if [[ "$PURGE" == "true" ]]; then
    for d in "${STACK_DIRS[@]}"; do
        info "Removing directory: $d"
        rm -rf "$d"
    done
    success "HermesStack and all associated data completely purged."
else
    for d in "${STACK_DIRS[@]}"; do
        info "Preserved data directory: $d (Run with --purge to delete)"
    done
    success "HermesStack containers stopped and CLI removed."
fi
