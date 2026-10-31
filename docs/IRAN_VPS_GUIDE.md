# Running HermesStack on Iranian VPS & Restricted Networks

Iranian servers face severe network restrictions when communicating with international infrastructure:
1. Docker Hub and container registries block Iranian IP addresses (HTTP 403 Forbidden).
2. National network filtering blocks OpenAI, Anthropic, and other AI inference providers.
3. DNS hijacking / poisoning alters international domain queries to `10.10.34.x`.
4. High packet fragmentation and low ISP MTU thresholds cause TLS handshake failures.

HermesStack embeds dedicated mitigation tools for each bottleneck.

---

## 1. Automated Detection & Diagnostics

Run the integrated diagnostic suite:
```bash
aistack doctor
```

The doctor tests:
- Geolocation and country code
- DNS poisoning on international domains
- Reachability of Docker Hub registry
- Direct reachability of `api.openai.com`, `openrouter.ai`, and `api.anthropic.com`
- System memory and disk thresholds

To run the network restriction detector standalone:
```bash
aistack iran detect
```

---

## 2. Docker Registry Mirrors

When deploying in Iran, `manage.sh` can benchmark and configure domestic registry mirrors in `/etc/docker/daemon.json`:

```bash
sudo aistack iran setup-mirrors
```

Tested candidate mirrors:
- `https://docker.arvancloud.ir`
- `https://docker.iranserver.com`
- `https://registry.docker.ir`
- `https://docker.mwt.me`

The script tests latency, discards unreachable mirrors, merges the working ones into `/etc/docker/daemon.json`, and reloads the Docker daemon.

---

## 3. MTU Tuning for Packet Loss Prevention

If TLS handshakes fail intermittently on Iranian cloud providers, clamp the Docker daemon MTU:

```bash
sudo aistack iran set-mtu 1400
```

---

## 4. Offline Container Bundles

If the target server has zero international connectivity, export container images from an unrestricted machine:

```bash
# On foreign server or laptop with Docker:
git clone https://github.com/IHosseini083/HermesStack.git
cd HermesStack
./manage.sh bundle export /tmp/hermes-stack-bundle.tar.gz
```

Transfer the tarball to your Iranian VPS and import:
```bash
# On Iranian VPS:
aistack bundle import /path/to/hermes-stack-bundle.tar.gz
```

All required images (`9router`, `hermes-agent`, `caddy`, `xray`) are loaded offline into the Docker engine.
