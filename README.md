# NineStack

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-20.10+-blue.svg)](https://www.docker.com/)
[![Caddy](https://img.shields.io/badge/Caddy-2.x-00ACD7.svg)](https://caddyserver.com/)
[![9Router](https://img.shields.io/badge/9Router-Gateway-6366f1.svg)](https://github.com/decolua/9router)
[![Xray](https://img.shields.io/badge/Xray-Core-red.svg)](https://github.com/XTLS/Xray-core)

A production-ready, self-hosted AI deployment stack combining **9Router** (LLM routing & model gateway), **Caddy 2** (reverse proxy with auto-TLS and CDN Origin support), and an optional **Xray Core balancer** for high resilience under restricted internet conditions (e.g. Iranian VPSs).

External clients—including **Hermes Agent**, **Cursor**, **Cline**, **Roo Code**, and **Claude Code**—connect directly to 9Router's OpenAI-compatible endpoint.

---

## Table of Contents

- [Architecture](#architecture)
- [Quickstart](#quickstart)
- [Connecting External AI Clients](#connecting-external-ai-clients)
  - [Hermes Agent](#hermes-agent-manual-setup)
  - [Cursor / Cline / Roo / Claude Code](#cursor--cline--roo--claude-code)
  - [cURL Example](#curl-test)
- [Command Reference](#command-reference)
  - [Lifecycle & Diagnostics](#lifecycle--diagnostics)
  - [Resource Tuning & Auth](#resource-tuning--auth)
  - [Domain Management](#domain-management)
  - [Proxy & Censorship Circumvention](#proxy--censorship-circumvention)
  - [Backups & Rollback](#backups--rollback)
  - [Iran VPS Utilities](#iran-vps-utilities)
- [Multiple Domains & CDN Integration](#multiple-domains--cdn-integration)
- [Documentation](#documentation)
- [One-Liner Uninstallation](#one-liner-uninstallation)
- [Testing](#testing)
- [License](#license)

---

## Architecture

```
             AI Clients (Hermes Agent, Cursor, Cline, Claude Code)
                               │
                               ▼
                      ┌─────────────────┐
                      │  Caddy Gateway  │  (Ports 80/443, Auto-TLS / CDN Origin)
                      └────────┬────────┘
                               │
                               ▼
                      ┌─────────────────┐
                      │     9Router     │  (Port 20128)
                      │  LLM Gateway    │  (Admin UI + /v1 OpenAI API)
                      └────────┬────────┘
                               │
                               ▼ (Outbound AI API Requests)
                      ┌─────────────────┐
                      │  Proxy / Xray   │  (SOCKS5 10808 / HTTP 10809)
                      │  Core Balancer  │  (leastPing, geosite/geoip:ir direct)
                      └────────┬────────┘
                               │
                               ▼
        External AI APIs (OpenAI, Anthropic, OpenRouter, DeepSeek)
```

Detailed architecture specifications are available in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Quickstart

### One-Liner Installation

Install NineStack and create the `aistack` / `ninestack` system shortcuts:

```bash
curl -fsSL https://raw.githubusercontent.com/IHosseini083/nine-stack/main/install.sh | bash
```

The installer verifies prerequisites, downloads `manage.sh`, installs the `aistack` and `ninestack` CLI tools, and launches the interactive setup wizard.

---

## Connecting External AI Clients

9Router exposes an OpenAI-compatible API endpoint at:
- **Local / SSH Tunnel**: `http://127.0.0.1:20128/v1`
- **With Custom Domain**: `https://<your-domain>/v1`
- **Default API Key**: `sk_9router` (or custom keys created in 9Router Admin UI)

### Hermes Agent (Manual Setup)

Run Hermes Agent natively on your host machine or laptop connected to 9Router:

```bash
# 1. Point Hermes to 9Router
hermes config set model.provider custom
hermes config set model.base_url "http://127.0.0.1:20128/v1"
hermes config set model.api_key "sk_9router"
hermes config set model.default "gpt-4o"  # Or your configured model

# 2. Start chatting with Hermes
hermes chat
```

### Cursor / Cline / Roo / Claude Code

Configure your editor or coding agent with:
- **Provider**: OpenAI Compatible
- **Base URL**: `http://127.0.0.1:20128/v1` (or `https://<your-domain>/v1`)
- **API Key**: `sk_9router`
- **Model Name**: Enter any model configured in your 9Router dashboard

### cURL Test

```bash
curl -s http://127.0.0.1:20128/v1/models \
  -H "Authorization: Bearer sk_9router"
```

---

## Command Reference

Manage NineStack interactively by running `aistack` or `ninestack`, or non-interactively using CLI subcommands:

### Lifecycle & Diagnostics
| Command | Description |
| :--- | :--- |
| `aistack setup` | Launch interactive configuration wizard |
| `aistack status` | View running containers, health status, domains, ports, and proxy |
| `aistack start` | Start all services |
| `aistack stop` | Stop all services |
| `aistack restart` | Restart all services |
| `aistack logs [service]` | Stream live container logs (`nine-router`, `caddy`, `xray`) |
| `aistack doctor` | Run comprehensive system, RAM, DNS poisoning, and API diagnostics |
| `aistack update` | Pull latest images with auto-backup and healthcheck verification |
| `aistack rollback` | Revert to previous container image digests if update failed |
| `aistack clients` | Display client connection instructions, endpoints, and credentials |

### Resource Tuning & Auth
| Command | Description |
| :--- | :--- |
| `aistack features status` | Show Caddy mode, 9Router heap cap, and API key enforcement |
| `aistack features caddy <auto\|on\|off>` | Control Caddy container (`auto` only starts Caddy when domains exist) |
| `aistack features memory <MB>` | Set 9Router Node.js V8 heap limit in MB (default: `256`, min: `128`) |
| `aistack features require-key <on\|off>` | Toggle strict API key enforcement vs permissive (`sk_9router`) |

### Domain Management
| Command | Description |
| :--- | :--- |
| `aistack domain list` | List active domains and detected CDN providers |
| `aistack domain add [dom] [tls]` | Add a domain (interactive or CLI flags: `domain add <domain> <tls_mode>`) |
| `aistack domain rm <domain>` | Remove domain and reload Caddy with zero downtime |
| `aistack domain sync` | Regenerate `Caddyfile` and reload Caddy |

### Proxy & Censorship Circumvention
| Command | Description |
| :--- | :--- |
| `aistack proxy status` | Display current outbound proxy mode and imported nodes |
| `aistack proxy add-link "<url>"` | Import a `vless://`, `vmess://`, `trojan://`, or `ss://` share link |
| `aistack proxy set-external "<url>"` | Route outbound AI traffic through an external HTTP/SOCKS5 proxy |
| `aistack proxy enable` / `disable` | Toggle proxy routing on or off |
| `aistack proxy clear` | Remove all imported Xray links |
| `aistack proxy env` | Output exportable `HTTP_PROXY`/`ALL_PROXY` variables for the host shell |
| `aistack proxy exec <cmd...>` | Execute any host command routed through the active Xray/external proxy |

### Backups & Rollback
| Command | Description |
| :--- | :--- |
| `aistack backup create [label]` | Create a complete, atomic backup (SQLite + SSL certificates + configs) |
| `aistack backup list` | List available backup archives in `backups/` |
| `aistack backup restore [archive]` | Validate integrity and restore stack from backup |
| `aistack cron` | Schedule an automated daily backup at 03:00 |

### Iran VPS Utilities
| Command | Description |
| :--- | :--- |
| `aistack iran detect` | Check if host is affected by national filtering or DNS poisoning |
| `aistack iran setup-mirrors` | Benchmark and configure responsive Iranian Docker registry mirrors |
| `aistack iran set-mtu [mtu]` | Tune Docker daemon MTU (default: 1400) to stop packet fragmentation |
| `aistack bundle export [file]` | Export container images to an offline `.tar.gz` bundle |
| `aistack bundle import <file>` | Import container images from an offline bundle |

See [docs/IRAN_VPS_GUIDE.md](docs/IRAN_VPS_GUIDE.md) and [docs/PROXY_AND_XRAY.md](docs/PROXY_AND_XRAY.md) for step-by-step guides.

---

## Multiple Domains & CDN Integration

NineStack routes all domains directly to 9Router, serving both the Web Admin UI (`/admin`) and the OpenAI API (`/v1/*`):

- **Auto Mode (`auto`)**: Issues Let's Encrypt certificates with ZeroSSL fallback. Ideal for direct DNS pointing to the VPS.
- **Origin Mode (`origin`)**: Allows pasting Cloudflare or ArvanCloud Origin Certificates. Enables "Full (Strict)" SSL without ACME challenge failures.
- **Internal Mode (`internal`)**: Enables Caddy internal self-signed certificates for local setups and Tailscale networks.

---

## Documentation

Full guides and technical specifications are available in the [docs/](docs/README.md) directory:

- [System Architecture](docs/ARCHITECTURE.md)
- [Iran VPS & Network Resilience Guide](docs/IRAN_VPS_GUIDE.md)
- [Proxy & Xray Balancer Configuration](docs/PROXY_AND_XRAY.md)

---

## One-Liner Uninstallation

To remove NineStack:

```bash
curl -fsSL https://raw.githubusercontent.com/IHosseini083/nine-stack/main/uninstall.sh | bash
```

Options:
- Pass `--purge` to delete persistent databases, SSL certificates, and stack configurations.
- Pass `-y` to skip confirmation prompts.

---

## Testing

Run the included automated test suite:
```bash
./tests/selftest.sh
```

---

## License

This project is licensed under the [MIT License](LICENSE).
Author: [Iliya Hosseini](https://github.com/IHosseini083).
