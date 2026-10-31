# Proxy & Xray Configuration Guide

HermesStack provides two methods to route AI API calls through proxies:
1. **Embedded Xray Container** (imported share links with balancer).
2. **External Proxy URL** (existing SOCKS5, HTTP, or HTTPS proxy).

---

## Method 1: Embedded Xray Balancer (Recommended)

The embedded Xray container runs inside the Docker network (`xray:10808` for SOCKS5, `xray:10809` for HTTP). It automatically sets up an internal `leastPing` balancer across all imported nodes.

### Supported Share Links
- `vless://` (supports TCP, reality, TLS, WS)
- `vmess://` (standard Base64 JSON)
- `trojan://` (TLS, SNI)
- `ss://` (Shadowsocks Base64 format)

### Adding Nodes
Import nodes one by one via CLI:
```bash
aistack proxy add-link "vless://d41d8cd9-8f00-b204-e980-0998ecf8427e@1.2.3.4:443?security=reality&sni=cdn.example.com&pbk=xyz&type=tcp#Node1"
```

Or append multiple links directly into the stack directory:
```bash
nano /opt/ai-stack/xray/links.txt
```
Then regenerate the balancer configuration:
```bash
aistack restart
```

### Balancer & Observatory
- Automatically probes nodes every 60 seconds against `https://api.openai.com`.
- Selects the lowest-latency responsive node for all outbound requests.
- Routes Iranian domestic IPs (`geoip:ir`) and private RFC1918 subnets directly via the `direct` outbound.

---

## Method 2: External Proxy

If you already have a proxy running (e.g. V2rayA, Clash, SSH tunnel, or Tor):

```bash
aistack proxy set-external "socks5://10.0.0.1:1080"
# or
aistack proxy set-external "http://127.0.0.1:7890"
```

Restart the stack to apply:
```bash
aistack restart
```

---

## Inspecting and Toggling Proxy

Check current proxy configuration:
```bash
aistack proxy status
```

Temporarily disable proxy routing without deleting configuration:
```bash
aistack proxy disable
aistack restart
```

Re-enable:
```bash
aistack proxy enable
aistack restart
```

Clear all imported Xray links:
```bash
aistack proxy clear
```
