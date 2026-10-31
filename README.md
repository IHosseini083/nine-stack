# HermesStack

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-20.10+-blue.svg)](https://www.docker.com/)
[![Caddy](https://img.shields.io/badge/Caddy-2.x-00ACD7.svg)](https://caddyserver.com/)
[![9Router](https://img.shields.io/badge/9Router-Gateway-6366f1.svg)](https://github.com/decolua/9router)
[![Hermes Agent](https://img.shields.io/badge/Hermes-Agent-black.svg)](https://nousresearch.com/)

A production-ready, self-hosted AI deployment stack combining **9Router** (LLM routing & proxy), **Hermes Agent** (autonomous agent supervisor & dashboard), **Caddy 2** (reverse proxy with auto-TLS and CDN Origin support), and an optional **Xray Core balancer** for high resilience under restricted internet conditions (e.g. Iranian VPSs).

---

## Table of Contents

- [Architecture](#architecture)
- [Quickstart](#quickstart)
- [Command Reference](#command-reference)
  - [Lifecycle & Status](#lifecycle--status)
  - [Domain Management](#domain-management)
  - [Proxy & Censorship Circumvention](#proxy--censorship-circumvention)
  - [Backups & Rollback](#backups--rollback)
  - [Iran VPS Utilities](#iran-vps-utilities)
- [Multiple Domains & CDN Integration](#multiple-domains--cdn-integration)
- [Safe Configuration & Extensibility](#safe-configuration--extensibility)
- [Documentation](#documentation)
- [One-Liner Uninstallation](#one-liner-uninstallation)
- [Testing](#testing)
- [License](#license)

---

## Architecture

```
                      Internet / Clients
                             │
                             ▼
                    ┌─────────────────┐
                    │  Caddy Gateway  │  (Ports 80/443, Auto-TLS / CDN Origin)
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
     ┌─────────────────┐           ┌─────────────────┐
     │     9Router     │           │   Hermes Agent  │
     │  (Port 20128)   │           │  (Port 9119)    │
     │  Model Gateway  │           │  Autonomous AI  │
     └────────┬────────┘           └────────┬────────┘
              │                             │
              └──────────────┬──────────────┘
                             │
                             ▼ (Outbound AI API Requests)
                    ┌─────────────────┐
                    │  Proxy / Xray   │  (SOCKS5 10808 / HTTP 10809)
                    │  Core Balancer  │  (leastPing, geosite/geoip:ir direct)
                    └────────┬────────┘
                             │
                             ▼
              External AI APIs (OpenAI, Anthropic, OpenRouter)
```

Detailed architecture specifications are available in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Quickstart

### One-Liner Installation

Install HermesStack and create the `aistack` system shortcut:

```bash
curl -fsSL https://raw.githubusercontent.com/IHosseini083/HermesStack/main/install.sh | bash
```

The installer verifies prerequisites, downloads `manage.sh`, installs the `aistack` CLI tool, and launches the interactive setup wizard.

---

## Command Reference

HermesStack can be managed interactively by running `aistack`, or non-interactively using CLI subcommands:

### Lifecycle & Status
| Command | Description |
| :--- | :--- |
| `aistack setup` | Launch interactive configuration wizard |
| `aistack status` | View running containers, health status, domains, ports, and proxy |
| `aistack start` | Start all services |
| `aistack stop` | Stop all services |
| `aistack restart` | Restart all services |
| `aistack logs [service]` | Stream live container logs (`nine-router`, `hermes`, `caddy`, `xray`) |
| `aistack doctor` | Run comprehensive system, RAM, DNS poisoning, and API diagnostics |
| `aistack update` | Pull latest images with auto-backup and healthcheck verification |
| `aistack rollback` | Revert to previous container image digests if update failed |

### Domain Management
| Command | Description |
| :--- | :--- |
| `aistack domain list` | List active domains and detected CDN providers |
| `aistack domain add` | Add a domain (interactive or CLI flags: `domain add <domain> <service> <tls_mode>`) |
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

HermesStack supports routing traffic through Cloudflare or ArvanCloud CDNs as well as direct DNS:

- **Auto Mode (`auto`)**: Issues Let's Encrypt certificates with ZeroSSL fallback. Ideal for direct DNS pointing to the VPS.
- **Origin Mode (`origin`)**: Allows pasting Cloudflare or ArvanCloud Origin Certificates. Enables "Full (Strict)" SSL without ACME challenge failures.
- **Internal Mode (`internal`)**: Enables Caddy internal self-signed certificates for local setups and Tailscale networks.

---

## Safe Configuration & Extensibility

- **Non-Destructive Hermes Config Merging**: Editing model keys or public URLs only touches the `model:` and `dashboard:` blocks of `hermes/config.yaml`. Custom tools, skills, and memory databases are never overwritten.
- **User Overrides**:
  - `Caddyfile.d/custom`: Place custom Caddy route blocks here.
  - `docker-compose.override.yml`: Place additional Docker Compose services or volume mounts here.
- **Safe Secrets**: All JWT, API, and salt keys are generated using `openssl rand -hex` and persisted with strict permissions (`chmod 600 .env`).

---

## Documentation

Full guides and technical specifications are available in the [docs/](docs/README.md) directory:

- [System Architecture](docs/ARCHITECTURE.md)
- [Iran VPS & Network Resilience Guide](docs/IRAN_VPS_GUIDE.md)
- [Proxy & Xray Balancer Configuration](docs/PROXY_AND_XRAY.md)

---

## One-Liner Uninstallation

To remove HermesStack:

```bash
curl -fsSL https://raw.githubusercontent.com/IHosseini083/HermesStack/main/uninstall.sh | bash
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
