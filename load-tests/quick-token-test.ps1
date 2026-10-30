################################################################################
# quick-token-test.ps1 — Single-request admission engine check
#
# Tests all 3 admission verdicts with a token value you specify.
# Great for quick smoke-testing after a sidecar restart.
#
# Usage:
#   .\load-tests\quick-token-test.ps1
#   .\load-tests\quick-token-test.ps1 -Tokens 5 -Port 9550
################################################################################

param(
    [int]   $Tokens = 100,
    [int]   $Port   = 9550,
    [string]$Path   = "/tools.descartes.teastore.webui/"
)

$CurlExe = "C:\Windows\System32\curl.exe"
$Base    = "http://localhost:$Port$Path"

Write-Host ""
Write-Host "=== Rajomon-HTTP Quick Token Test ===" -ForegroundColor Cyan
Write-Host "  Sidecar : http://localhost:$Port"
Write-Host "  Path    : $Path"
Write-Host ""

# 1. FORWARD
Write-Host "[1] FORWARD  X-Rajomon-Tokens: $Tokens" -ForegroundColor Yellow
$out = & $CurlExe -si -H "X-Rajomon-Tokens: $Tokens" $Base
($out | Select-String "^HTTP/|x-rajomon" -CaseSensitive:$false) | ForEach-Object { Write-Host "     $_" }

Write-Host ""

# 2. REJECT
Write-Host "[2] REJECT   X-Rajomon-Tokens: 0" -ForegroundColor Yellow
$out2 = & $CurlExe -si -H "X-Rajomon-Tokens: 0" $Base
($out2 | Select-String "^HTTP/|rajomon" -CaseSensitive:$false) | ForEach-Object { Write-Host "     $_" }

Write-Host ""

# 3. FAIL-OPEN
Write-Host "[3] FAIL-OPEN (no token header)" -ForegroundColor Yellow
$out3 = & $CurlExe -si $Base
($out3 | Select-String "^HTTP/|x-rajomon" -CaseSensitive:$false) | ForEach-Object { Write-Host "     $_" }

Write-Host ""
Write-Host "Sidecar log (last 5 lines):" -ForegroundColor DarkGray
docker compose logs --tail=5 sidecar-webui 2>&1
