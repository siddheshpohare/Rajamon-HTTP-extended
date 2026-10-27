#!/usr/bin/env bash
################################################################################
# header-survival-check.sh — Linux/macOS Bash
#
# Tests whether X-Rajomon-Tokens survives a real Envoy gateway hop.
#
# Prerequisites:
#   docker compose --profile permissive up -d   (for PASS test)
#   docker compose --profile hardened  up -d    (for FAIL test)
#
# Usage:
#   bash load-tests/header-survival-check.sh
################################################################################

GATEWAY_URL="${1:-http://localhost:10000/tools.descartes.teastore.webui/}"
SIDECAR_SERVICE="${2:-sidecar-webui}"
TOKEN_VALUE="${3:-100}"

echo ""
echo "=== Rajomon-HTTP Header Survival Check (TeaStore) ==="
echo "  Gateway:  $GATEWAY_URL"
echo "  Sidecar:  $SIDECAR_SERVICE"
echo "  Token:    X-Rajomon-Tokens: $TOKEN_VALUE"
echo ""

# Send one request through the gateway with the token header
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-Rajomon-Tokens: $TOKEN_VALUE" \
    --max-time 10 \
    "$GATEWAY_URL")

echo "  HTTP Status: $HTTP_STATUS"
echo ""
echo "--- Last 10 sidecar-webui log lines ---"
docker compose logs --tail=10 "$SIDECAR_SERVICE"

echo ""
echo "--- Interpretation ---"
echo "  FORWARD  tokens=... → header survived the gateway hop (PASS)"
echo "  FAIL-OPEN           → header was stripped by gateway (FAIL — hardened profile)"
echo ""
