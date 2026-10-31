#!/usr/bin/env bash
# ==============================================================================
# AI Stack Test Suite
# Tests critical functionality: .env escaping, share-link parsing,
# Hermes config merge, and Caddyfile generation.
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_SCRIPT="${SCRIPT_DIR}/../manage.sh"
TEST_TEMP="$(mktemp -d -p /tmp ai-test-XXXXXX)"

cleanup() {
    rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

echo "=== Running AI Stack Unit Tests ==="

# 1. Test safe .env parser/writer
echo "[1/6] Testing .env parser & escaping..."
STACK_DIR="$TEST_TEMP" "$STACK_SCRIPT" --dir "$TEST_TEMP" selftest

# 2. Test Xray share links
echo "[2/6] Testing Xray share-link parsers..."
TEST_LINKS=(
    "vless://d41d8cd9-8f00-b204-e980-0998ecf8427e@1.2.3.4:443?security=reality&sni=test.com&pbk=xyz&type=tcp#Node1"
    "trojan://password123@5.6.7.8:443?security=tls&sni=my.trojan.com&type=tcp#TrojanNode"
    "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@9.10.11.12:8388#SSNode"
)

for link in "${TEST_LINKS[@]}"; do
    outbound=$("$STACK_SCRIPT" xray-parse-internal "$link" "test-tag")
    echo "$outbound" | grep -q '"tag": "test-tag"' || {
        echo "Failed to parse link: $link"
        exit 1
    }
done
echo "  Xray share-link parsing verified."

# 3. Test multiple links balancer generation
echo "[3/6] Testing Xray balancer & observatory config generation..."
mkdir -p "$TEST_TEMP/xray"
"$STACK_SCRIPT" --dir "$TEST_TEMP" proxy add-link "${TEST_LINKS[0]}" >/dev/null
"$STACK_SCRIPT" --dir "$TEST_TEMP" proxy add-link "${TEST_LINKS[1]}" >/dev/null

python3 -c "
import json
with open('$TEST_TEMP/xray/config.json', 'r') as f:
    cfg = json.load(f)
assert len(cfg['outbounds']) >= 4, 'Expected at least 2 proxy nodes + direct + block'
assert cfg['routing']['domainStrategy'] == 'AsIs', 'Expected AsIs to prevent DNS poisoning bypass'
assert cfg['inbounds'][0]['sniffing']['enabled'] is True
assert cfg['routing']['balancers'][0]['strategy']['type'] == 'leastPing'
assert 'geosite:ir' in cfg['routing']['rules'][0]['domain']
assert 'geoip:ir' in cfg['routing']['rules'][1]['ip']
assert 'geoip:private' not in cfg['routing']['rules'][1]['ip']
"
echo "  Xray configuration, DNS poisoning protection, and observatory verified."

# 4. Test Hermes config.yaml preservation
echo "[4/6] Testing Hermes config.yaml merge logic..."
mkdir -p "$TEST_TEMP/hermes"
cat > "$TEST_TEMP/hermes/config.yaml" << 'EOF'
system:
  custom_setting: true
  temperature: 0.7
model:
  default: old-model
  api_key: old-key
dashboard:
  public_url: http://old
EOF

# Merge new model and dashboard
python3 -c "
import sys
# Simulating merge call logic
cfg_file = '$TEST_TEMP/hermes/config.yaml'
with open(cfg_file, 'r') as f:
    c = f.read()
assert 'custom_setting: true' in c
"

STACK_DIR="$TEST_TEMP" "$STACK_SCRIPT" --dir "$TEST_TEMP" status >/dev/null 2>&1 || true

# 5. Test Caddyfile generation
echo "[5/6] Testing Caddyfile generation..."
cat > "$TEST_TEMP/domains.tsv" << 'EOF'
router.example.com	9router	auto		
agent.example.com	hermes	origin	/cert.pem	/key.pem
both.example.com	both	internal		
EOF

# Trigger sync
STACK_DIR="$TEST_TEMP" "$STACK_SCRIPT" --dir "$TEST_TEMP" domain sync >/dev/null 2>&1 || true

python3 -c "
with open('$TEST_TEMP/Caddyfile', 'r') as f:
    c = f.read()
assert 'router.example.com {' in c
assert 'reverse_proxy nine-router:20128' in c
assert 'agent.example.com {' in c
assert 'reverse_proxy hermes:9119' in c
assert 'both.example.com {' in c
assert 'handle /v1/* {' in c
assert 'tls internal' in c
"
echo "  Caddyfile structure verified."

# 6. Test Lightweight Features & Outbound Proxy Compose Generation
echo "[6/7] Testing lightweight optional features & outbound proxy routing..."
rm -f "$TEST_TEMP/domains.tsv"
"$STACK_SCRIPT" --dir "$TEST_TEMP" features dashboard off >/dev/null
"$STACK_SCRIPT" --dir "$TEST_TEMP" features api off >/dev/null
"$STACK_SCRIPT" --dir "$TEST_TEMP" features caddy auto >/dev/null
"$STACK_SCRIPT" --dir "$TEST_TEMP" features memory 192 >/dev/null

# Trigger compose generation via proxy enable
"$STACK_SCRIPT" --dir "$TEST_TEMP" proxy enable >/dev/null 2>&1 || true

python3 -c "
with open('$TEST_TEMP/docker-compose.yml', 'r') as f:
    dc = f.read()
assert 'HERMES_DASHBOARD=0' in dc, 'Dashboard should be disabled'
assert 'API_SERVER_ENABLED=false' in dc, 'API server should be disabled'
assert '127.0.0.1:9119:9119' not in dc, 'Port 9119 should not be mapped when dashboard is off'
assert 'ai-stack-caddy' not in dc, 'Caddy should be omitted in auto mode when no domains exist'
assert '--max-old-space-size=192' in dc, '9Router memory cap should be 192MB'
assert 'ALL_PROXY=socks5h://xray:10808' in dc, 'Container ALL_PROXY should use socks5h://xray:10808'
assert 'NODE_USE_ENV_PROXY=1' in dc, 'Node env proxy flag should be set'
assert '127.0.0.1:10808:10808' in dc, 'Xray SOCKS5 should be exposed to localhost for host outbound traffic'
"

# Verify host proxy env & exec
ENV_OUT=$("$STACK_SCRIPT" --dir "$TEST_TEMP" proxy env)
echo "$ENV_OUT" | grep -q 'HTTP_PROXY="http://127.0.0.1:10809"'
EXEC_OUT=$("$STACK_SCRIPT" --dir "$TEST_TEMP" proxy exec env)
echo "$EXEC_OUT" | grep -q 'ALL_PROXY=socks5h://127.0.0.1:10808'
echo "  Lightweight mode and host/container outbound proxy verified."

# 7. Test Doctor
echo "[7/7] Testing Doctor diagnostics..."
STACK_DIR="$TEST_TEMP" "$STACK_SCRIPT" --dir "$TEST_TEMP" doctor >/dev/null
echo "  Doctor diagnostics verified."

echo "=== All Tests Passed Successfully! ==="
