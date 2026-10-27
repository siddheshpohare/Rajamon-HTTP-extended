################################################################################
# header-survival-check.ps1 — Windows PowerShell
#
# Tests whether X-Rajomon-Tokens survives a real Envoy gateway hop.
#
# Prerequisites:
#   docker compose --profile permissive up -d   (for PASS test)
#   docker compose --profile hardened  up -d    (for FAIL test)
#
# Usage:
#   .\load-tests\header-survival-check.ps1
################################################################################

param(
    [string]$GatewayUrl  = "http://localhost:10000/tools.descartes.teastore.webui/",
    [string]$SidecarLogs = "sidecar-webui",
    [int]   $TokenValue  = 100
)

Write-Host ""
Write-Host "=== Rajomon-HTTP Header Survival Check (TeaStore) ===" -ForegroundColor Cyan
Write-Host "  Gateway:  $GatewayUrl"
Write-Host "  Sidecar:  $SidecarLogs"
Write-Host "  Token:    X-Rajomon-Tokens: $TokenValue"
Write-Host ""

# Send one request through the gateway with the token header
$headers = @{ "X-Rajomon-Tokens" = "$TokenValue" }
try {
    $response = Invoke-WebRequest -Uri $GatewayUrl -Headers $headers -Method GET `
                                  -TimeoutSec 10 -ErrorAction Stop
    Write-Host "  HTTP Status: $($response.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "  HTTP request failed: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "--- Last 10 sidecar-webui log lines ---" -ForegroundColor Yellow
docker compose logs --tail=10 $SidecarLogs

Write-Host ""
Write-Host "--- Interpretation ---" -ForegroundColor Cyan
Write-Host "  FORWARD  tokens=... → header survived the gateway hop (PASS)"
Write-Host "  FAIL-OPEN           → header was stripped by gateway (FAIL — hardened profile)"
Write-Host ""
