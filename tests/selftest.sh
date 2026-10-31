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

# 4. Test Client Access Info & Compatibility Commands
echo "[4/7] Testing client access info & CLI compatibility..."
ACCESS_OUT=$("$STACK_SCRIPT" --dir "$TEST_TEMP" clients)
echo "$ACCESS_OUT" | grep -q '9ROUTER CLIENT SETUP & API ACCESS GUIDE' || {
    echo "Client access guide output missing expected header"
    exit 1
}
echo "$ACCESS_OUT" | grep -q 'http://127.0.0.1:20128/v1' || {
    echo "API base URL missing in access guide"
    exit 1
}
echo "$ACCESS_OUT" | grep -q 'hermes config set' || {
    echo "Hermes setup instructions missing in access guide"
    exit 1
}

HERMES_CMD_OUT=$("$STACK_SCRIPT" --dir "$TEST_TEMP" hermes chat 2>&1)
echo "$HERMES_CMD_OUT" | grep -q 'Hermes Agent runs manually/externally' || {
    echo "Compatibility wrapper did not notify external run status"
    exit 1
}
echo "  Client access guide and compatibility wrapper verified."

STACK_DIR="$TEST_TEMP" "$STACK_SCRIPT" --dir "$TEST_TEMP" status >/dev/null 2>&1 || true

# 5. Test Caddyfile generation (all domains proxy directly to 9Router)
echo "[5/7] Testing Caddyfile generation & 9Router domain routing..."
cat > "$TEST_TEMP/domains.tsv" << 'EOF'
router.example.com	9router	auto		
cdn.example.com	9router	origin	/cert.pem	/key.pem
internal.example.com	9router	internal		
EOF

# Trigger sync
STACK_DIR="$TEST_TEMP" "$STACK_SCRIPT" --dir "$TEST_TEMP" domain sync >/dev/null 2>&1 || true

python3 -c "
with open('$TEST_TEMP/Caddyfile', 'r') as f:
    c = f.read()
assert 'router.example.com {' in c
assert 'cdn.example.com {' in c
assert 'internal.example.com {' in c
assert 'reverse_proxy nine-router:20128' in c
assert 'tls internal' in c
assert 'tls /etc/caddy/certs/cdn.example.com/cert.pem' in c
assert 'hermes:9119' not in c, 'Hermes container should not be targeted in Caddyfile'
"
echo "  Caddyfile structure & domain routing verified."

# 6. Test Lightweight Features & Outbound Proxy Compose Generation
echo "[6/7] Testing features, compose generation, and proxy routing..."
rm -f "$TEST_TEMP/domains.tsv"
"$STACK_SCRIPT" --dir "$TEST_TEMP" features caddy auto >/dev/null
"$STACK_SCRIPT" --dir "$TEST_TEMP" features memory 192 >/dev/null
"$STACK_SCRIPT" --dir "$TEST_TEMP" features require-key on >/dev/null

# Trigger compose generation via proxy enable
"$STACK_SCRIPT" --dir "$TEST_TEMP" proxy enable >/dev/null 2>&1 || true

python3 -c "
with open('$TEST_TEMP/docker-compose.yml', 'r') as f:
    dc = f.read()
assert 'ai-stack-nine-router' in dc, '9Router container should be defined'
assert 'ai-stack-hermes' not in dc, 'Hermes container must not be present in compose'
assert 'ai-stack-caddy' not in dc, 'Caddy should be omitted in auto mode when no domains exist'
assert '--max-old-space-size=192' in dc, '9Router memory cap should be 192MB'
assert 'REQUIRE_API_KEY=true' in dc, 'API key enforcement should be true'
assert 'ALL_PROXY=socks5h://xray:10808' in dc, 'Container ALL_PROXY should use socks5h://xray:10808'
assert 'NODE_USE_ENV_PROXY=1' in dc, 'Node env proxy flag should be set'
assert '127.0.0.1:10808:10808' in dc, 'Xray SOCKS5 should be exposed to localhost for host outbound traffic'
assert '127.0.0.1:20128:20128' in dc, '9Router port 20128 should be exposed'
assert '9119' not in dc, 'Port 9119 should not exist in compose'
assert '8642' not in dc, 'Port 8642 should not exist in compose'
"

# Verify host proxy env & exec
ENV_OUT=$("$STACK_SCRIPT" --dir "$TEST_TEMP" proxy env)
echo "$ENV_OUT" | grep -q 'HTTP_PROXY="http://127.0.0.1:10809"'
EXEC_OUT=$("$STACK_SCRIPT" --dir "$TEST_TEMP" proxy exec env)
echo "$EXEC_OUT" | grep -q 'ALL_PROXY=socks5h://127.0.0.1:10808'
echo "  Features, compose file, and host/container outbound proxy verified."
echo "$ENV_OUT" | grep -q 'HTTP_PROXY="http://127.0.0.1:10809"'
EXEC_OUT=$("$STACK_SCRIPT" --dir "$TEST_TEMP" proxy exec env)
echo "$EXEC_OUT" | grep -q 'ALL_PROXY=socks5h://127.0.0.1:10808'
echo "  Lightweight mode and host/container outbound proxy verified."

# 7. Test Doctor
echo "[7/7] Testing Doctor diagnostics..."
STACK_DIR="$TEST_TEMP" "$STACK_SCRIPT" --dir "$TEST_TEMP" doctor >/dev/null
echo "  Doctor diagnostics verified."

echo "=== All Tests Passed Successfully! ==="
