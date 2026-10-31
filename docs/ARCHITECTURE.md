# HermesStack Architecture

HermesStack is a production-grade, self-hosted AI deployment stack optimized for autonomous AI agents, multi-model routing, and high resilience in restricted network environments.

## Component Overview

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

### 1. Reverse Proxy & Edge: Caddy 2
- **Dynamic Configuration**: Automatically managed via `manage.sh domain add/rm/sync` and `domains.tsv`.
- **TLS Automation**:
  - `auto`: Dual-issuer ACME fallback (ZeroSSL + Let's Encrypt).
  - `origin`: Dedicated TLS termination for Cloudflare & ArvanCloud CDN Origin Certificates.
  - `internal`: Self-signed / local TLS for intranet and Tailscale.
- **Graceful Reload**: Uses `caddy validate` and `caddy reload` without downtime or dropping active websockets/streams.
- **Custom Overrides**: Drop custom Caddy directives in `Caddyfile.d/custom` without modifying core templates.

### 2. AI Model Gateway: 9Router
- **Role**: High-performance reverse proxy and router for OpenAI, Anthropic, OpenRouter, and local LLM backends.
- **Database**: SQLite WAL mode with atomic vacuum backup routines.
- **Security**: Mandatory auto-generated `JWT_SECRET`, `API_KEY_SECRET`, and `MACHINE_ID_SALT`.
- **Traffic Routing**: Supports upstream proxy injection (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`).

### 3. Agent Runtime: Hermes Agent Gateway
- **Role**: Autonomous AI agent runner, supervisor, and dashboard.
- **Interface**: Web Dashboard on port `9119`, API server on port `8642`.
- **Configuration Merging**: `manage.sh` merges top-level `model:` and `dashboard:` configurations without overwriting skills, tools, or memory configs in `hermes/config.yaml`.
- **Permissions**: Enforces UID `10000:10000` compatibility for rootless container execution.

### 4. Anti-Censorship Outbound: Xray Balancer
- **Multi-Node Ingestion**: Parses `vless://`, `vmess://`, `trojan://`, and `ss://` share links.
- **Observatory & Balancer**: Probes nodes with `leastPing` strategy.
- **Split Routing**: Routes domestic Iranian traffic (`geoip:ir`, `geoip:private`) directly while sending AI API calls through the optimal proxy outbound.
