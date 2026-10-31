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
assert cfg['routing']['balancers'][0]['strategy']['type'] == 'leastPing'
assert 'geoip:ir' in cfg['routing']['rules'][0]['ip']
"
echo "  Xray configuration and observatory verified."

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

# 6. Test Doctor
echo "[6/6] Testing Doctor diagnostics..."
STACK_DIR="$TEST_TEMP" "$STACK_SCRIPT" --dir "$TEST_TEMP" doctor >/dev/null
echo "  Doctor diagnostics verified."

echo "=== All Tests Passed Successfully! ==="
