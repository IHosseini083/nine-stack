# NineStack Architecture

NineStack is a production-grade, self-hosted AI deployment stack combining **9Router** (LLM routing & model gateway), **Caddy 2** (reverse proxy with auto-TLS and CDN Origin support), and an optional **Xray Core balancer** for high resilience under restricted internet conditions.

Autonomous AI agents (such as Hermes Agent) and IDE clients (Cursor, Cline, Roo, Claude Code) connect directly to 9Router over its OpenAI-compatible endpoint.

## Component Overview

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

### 1. Reverse Proxy & Edge: Caddy 2
- **Unified Domain Routing**: All configured domains proxy directly to `nine-router:20128`, serving both the 9Router Admin UI (`/admin`) and the OpenAI API (`/v1/*`).
- **Dynamic Configuration**: Automatically managed via `manage.sh domain add/rm/sync` and `domains.tsv`.
- **TLS Automation**:
  - `auto`: Dual-issuer ACME fallback (ZeroSSL + Let's Encrypt).
  - `origin`: Dedicated TLS termination for Cloudflare & ArvanCloud CDN Origin Certificates.
  - `internal`: Self-signed / local TLS for intranet and Tailscale.
- **Graceful Reload**: Uses `caddy validate` and `caddy reload` without dropping active connections.
- **Custom Overrides**: Drop custom Caddy directives into `Caddyfile.d/custom` without modifying core templates.

### 2. AI Model Gateway: 9Router
- **Role**: High-performance reverse proxy and model router for OpenAI, Anthropic, OpenRouter, Google, and self-hosted models.
- **Endpoints**:
  - Admin UI: `http://localhost:20128/admin` (or `https://<domain>/admin`)
  - OpenAI Base URL: `http://localhost:20128/v1` (or `https://<domain>/v1`)
- **Database**: SQLite WAL mode with atomic backup routines.
- **Security**: Mandatory auto-generated `JWT_SECRET`, `API_KEY_SECRET`, and `MACHINE_ID_SALT`.
- **Resource Limits**: Configurable V8 heap limit (`--max-old-space-size=256` by default, tunable down to 192MB).
- **Traffic Routing**: Supports upstream proxy injection (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`).

### 3. Anti-Censorship Outbound: Xray Balancer
- **Multi-Node Ingestion**: Parses `vless://`, `vmess://`, `trojan://`, and `ss://` share links.
- **Observatory & Balancer**: Periodically probes nodes using `leastPing` strategy.
- **Split Routing**: Domestic Iranian traffic (`geosite:ir`, `geoip:ir`) routes directly while AI API calls route through the fastest working outbound proxy.
- **Host Integration**: Exposes local SOCKS5 (`127.0.0.1:10808`) and HTTP (`127.0.0.1:10809`) proxies so host CLI tools (including Hermes Agent run natively) can route through the same proxy tunnel.

### 4. Client Integration (Hermes Agent & IDEs)
- **External Client Model**: Decoupling the client from Docker gives full control over Python virtualenvs, local development tools, terminal skills, and interactive agents.
- **Hermes Agent Connection**:
  ```bash
  hermes config set model.provider custom
  hermes config set model.base_url "http://127.0.0.1:20128/v1"
  hermes config set model.api_key "sk_9router"
  hermes config set model.default "<model-name>"
  hermes chat
  ```
- **Cursor / Cline / Roo / Claude Code**: Configure as OpenAI-compatible with Base URL `http://127.0.0.1:20128/v1` (or your domain `https://ai.example.com/v1`) and API Key `sk_9router`.
