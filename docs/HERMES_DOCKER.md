# Standalone Hermes Agent in Docker

`scripts/hermes-docker.sh` is an independent management script that runs the Nous Research **Hermes Agent** (`nousresearch/hermes-agent:latest`) inside a Docker container while giving you direct control over models, gateways, credentials, and container lifecycles.

It decouples the agent from the core NineStack deployment, allowing you to run, restart, or reconfigure Hermes Agent without modifying the 9Router gateway stack.

---

## Quickstart

### 1. Install CLI Shortcut

Install the `hermes-docker` shortcut to `/usr/local/bin` (or `~/.local/bin` if non-root):

```bash
./scripts/hermes-docker.sh shortcut
```

### 2. Configure Gateway & Model

You can run the interactive setup wizard:

```bash
hermes-docker setup
```

Or configure parameters directly via CLI:

```bash
# Point Hermes to NineStack's 9Router gateway
hermes-docker gateway "http://127.0.0.1:20128/v1" "sk_9router"

# Set default model
hermes-docker model "gpt-4o"
```

### 3. Start the Daemon

Start the Hermes background container (runs `gateway run`):

```bash
hermes-docker start
```

Once running:
- **Web UI**: [http://localhost:9119](http://localhost:9119)
- **API Server**: [http://localhost:8642](http://localhost:8642)

---

## Interacting with the Agent

### Terminal Chat & TUI
Launch an interactive conversation directly in your terminal:

```bash
# Standard interactive chat session
hermes-docker chat

# Fullscreen Terminal UI (TUI)
hermes-docker tui
```

### Shell & Manual Execution
Drop into an interactive bash shell inside the container:

```bash
hermes-docker shell
```

Or run arbitrary commands inside the container:

```bash
hermes-docker exec hermes skills list
hermes-docker exec hermes plugins list
```

---

## Configuration Reference

All persistent state (configurations, session logs, custom skills) is preserved in `~/.hermes-agent` on the host:

- `~/.hermes-agent/config.yaml`: Core agent configuration.

### Viewing & Editing Config

```bash
# View current config
hermes-docker config show

# Open config in $EDITOR
hermes-docker config edit
```

Sample `config.yaml`:

```yaml
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
```

---

## Network & Proxy Handling

- **Linux**: Runs with `--network=host`, allowing Hermes to resolve `127.0.0.1:20128` (9Router) directly without container bridge complexity.
- **macOS / Windows**: Port forwarding (`9119`, `8642`) with `host.docker.internal` host gateway resolution.
- **Outbound Censorship Bypass**: If NineStack's local outbound proxy (`http://127.0.0.1:10809`) is detected, `hermes-docker` automatically injects `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` variables into the container.

---

## Command Summary

| Command | Description |
| :--- | :--- |
| `hermes-docker setup` | Interactive wizard to configure gateway, key, and model |
| `hermes-docker start` | Start Hermes background daemon container |
| `hermes-docker stop` | Stop and remove the Hermes container |
| `hermes-docker restart` | Restart the daemon container |
| `hermes-docker status` | Show container state, ports, active model, and gateway |
| `hermes-docker chat` | Start interactive CLI chat session |
| `hermes-docker tui` | Start fullscreen Terminal UI |
| `hermes-docker model [name]` | View or set default model |
| `hermes-docker gateway [url] [key]` | View or set gateway base URL and API key |
| `hermes-docker config <show\|edit>` | View or edit `config.yaml` |
| `hermes-docker shell` | Open bash shell inside container |
| `hermes-docker logs [-f]` | Stream daemon container logs |
| `hermes-docker pull` | Pull latest `nousresearch/hermes-agent:latest` image |
| `hermes-docker shortcut` | Install `hermes-docker` symlink into PATH |
