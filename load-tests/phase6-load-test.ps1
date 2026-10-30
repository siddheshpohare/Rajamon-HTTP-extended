################################################################################
# phase6-load-test.ps1 — Phase 6 Load & Spike Test Suite (Windows PowerShell)
#
# Runs all Phase 6 test scenarios against Rajomon-HTTP using Docker wrk.
# Requires: Docker Desktop running, stack up with permissive profile.
#
# Prerequisites:
#   Set-Location D:\Rajamon-HTTP
#   docker compose --profile permissive up -d
#
# Usage:
#   .\load-tests\phase6-load-test.ps1
#   .\load-tests\phase6-load-test.ps1 -Target http://localhost:10000   # via Envoy
#   .\load-tests\phase6-load-test.ps1 -Tokens 50 -Duration 60s
################################################################################

param(
    [string]$Target    = "http://localhost:9550",            # Direct sidecar or Envoy :10000
    [string]$Path      = "/tools.descartes.teastore.webui/",
    [int]   $Tokens    = 100,                                # X-Rajomon-Tokens value
    [string]$Duration  = "30s",                              # wrk duration
    [int]   $Threads   = 4,                                  # wrk threads
    [int]   $ConnNorm  = 20,                                 # connections for normal load
    [int]   $ConnSpike = 100                                 # connections for spike load
)

$FullUrl    = "$Target$Path"
$CurlExe    = "C:\Windows\System32\curl.exe"

function Write-Header($msg) {
    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor Cyan
}

function Test-SidecarHealthz {
    Write-Header "T1 - Sidecar Healthz (all 5 sidecars)"
    $ports = @(9550, 9551, 9552, 9553, 9554)
    $names = @("webui", "auth", "imageprovider", "recommender", "persistence")
    for ($i = 0; $i -lt $ports.Length; $i++) {
        $code = & $CurlExe -s -w "%{http_code}" -o NUL "http://localhost:$($ports[$i])/healthz"
        $icon = if ($code -eq "200") { "[PASS]" } else { "[FAIL]" }
        $color = if ($code -eq "200") { "Green" } else { "Red" }
        Write-Host "  $icon sidecar-$($names[$i]):$($ports[$i])/healthz -> HTTP $code" -ForegroundColor $color
    }
}

function Test-AdmissionEngine {
    Write-Header "T2 - Admission Engine: 3-Verdict Check"

    # FORWARD
    Write-Host "  [FORWARD]  tokens=$Tokens >= price (should be 200 + X-Rajomon-Price)" -ForegroundColor Yellow
    $out = & $CurlExe -si -H "X-Rajomon-Tokens: $Tokens" "$FullUrl"
    $status = ($out | Select-String "^HTTP/").Line
    $price  = ($out | Select-String "x-rajomon-price" -CaseSensitive:$false).Line
    Write-Host "             Status : $($status.Trim())"
    if ($price) {
        Write-Host "             $($price.Trim())" -ForegroundColor Green
    } else {
        Write-Host "             X-Rajomon-Price: MISSING [BUG]" -ForegroundColor Red
    }

    # REJECT
    Write-Host "  [REJECT]   tokens=0 < price (should be 503)" -ForegroundColor Yellow
    $code503 = & $CurlExe -s -w "%{http_code}" -o NUL -H "X-Rajomon-Tokens: 0" "$FullUrl"
    $icon = if ($code503 -eq "503") { "[PASS]" } else { "[FAIL]" }
    $color = if ($code503 -eq "503") { "Green" } else { "Red" }
    Write-Host "             $icon HTTP $code503 (expected 503)" -ForegroundColor $color

    # FAIL-OPEN
    Write-Host "  [FAIL-OPEN] no token header (should be 200 + X-Rajomon-Price)" -ForegroundColor Yellow
    $out2  = & $CurlExe -si "$FullUrl"
    $stat2 = ($out2 | Select-String "^HTTP/").Line
    $pri2  = ($out2 | Select-String "x-rajomon-price" -CaseSensitive:$false).Line
    Write-Host "             Status : $($stat2.Trim())"
    if ($pri2) {
        Write-Host "             $($pri2.Trim())" -ForegroundColor Green
    } else {
        Write-Host "             X-Rajomon-Price: MISSING [BUG]" -ForegroundColor Red
    }
}

function Test-HeaderSurvival {
    Write-Header "T3 - Header Survival Through Envoy (permissive)"
    $gwUrl = "http://localhost:10000$Path"
    $out = & $CurlExe -si -H "X-Rajomon-Tokens: $Tokens" $gwUrl
    $status = ($out | Select-String "^HTTP/").Line
    Write-Host "  Gateway URL  : $gwUrl"
    Write-Host "  Response     : $($status.Trim())"
    # Check sidecar log for FORWARD (not FAIL-OPEN) to confirm header survived
    $log = docker compose logs --tail=3 sidecar-webui 2>&1 | Select-String "FORWARD|FAIL-OPEN" | Select-Object -Last 1
    if ($log -match "FORWARD.*tokens=") {
        Write-Host "  Log confirms : [PASS] FORWARD (header survived gateway hop)" -ForegroundColor Green
    } else {
        Write-Host "  Log shows    : $log" -ForegroundColor Yellow
    }
}

function Test-MetricsEndpoints {
    Write-Header "T4 - Prometheus /metrics Endpoints"
    $ports = @(9550, 9551, 9552, 9553, 9554)
    foreach ($p in $ports) {
        $lines = (& $CurlExe -s "http://localhost:$p/metrics" | Select-String "rajomon_sidecar_requests_total").Count
        Write-Host "  port $p/metrics : $lines rajomon_sidecar_requests_total series"
    }
}

function Run-WrkLoad($label, $conns, $extraHeaders) {
    Write-Host ""
    Write-Host "  Running: wrk -t $Threads -c $conns -d $Duration $extraHeaders $FullUrl" -ForegroundColor DarkGray
    $args = @("-t", $Threads, "-c", $conns, "-d", $Duration)
    if ($extraHeaders) { $args += ($extraHeaders -split " ") }
    $args += $FullUrl
    $result = docker run --rm --network host williamyeh/wrk @args 2>&1
    $result | ForEach-Object { Write-Host "  $_" }
}

function Test-LoadNormal {
    Write-Header "T5 - Normal Load ($ConnNorm conn, tokens=$Tokens, $Duration)"
    Run-WrkLoad "normal" $ConnNorm "-H `"X-Rajomon-Tokens: $Tokens`""
}

function Test-LoadSpike {
    Write-Header "T6 - SPIKE Load ($ConnSpike conn, tokens=$Tokens, $Duration)"
    Write-Host "  [HIGH CONCURRENCY — watch admission engine respond to queue depth]" -ForegroundColor Yellow
    Run-WrkLoad "spike" $ConnSpike "-H `"X-Rajomon-Tokens: $Tokens`""
}

function Test-LoadRejection {
    Write-Header "T7 - Rejection Spike (tokens=1, below base_price=1.0)"
    Write-Host "  [SHOULD SEE: ~100% 503s at microsecond latency — fast-path rejection]" -ForegroundColor Yellow
    Run-WrkLoad "reject" $ConnSpike "-H `"X-Rajomon-Tokens: 1`""
}

function Test-LoadNoTokens {
    Write-Header "T8 - Fail-Open Load (no tokens header, $ConnNorm conn, $Duration)"
    Write-Host "  [SHOULD SEE: 200s — sidecar forwards in fail-open mode]" -ForegroundColor Yellow
    Run-WrkLoad "failopen" $ConnNorm ""
}

function Show-SidecarStats {
    Write-Header "T9 - Post-Load Sidecar Log Summary"
    docker compose logs --tail=20 sidecar-webui 2>&1 | Select-String "FORWARD|REJECT|FAIL-OPEN" | Select-Object -Last 10
}

# ─── MAIN ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗"
Write-Host "║        RAJOMON-HTTP — PHASE 6 LOAD TEST SUITE                  ║"
Write-Host "║  Target: $FullUrl" -NoNewline
Write-Host (" " * (62 - $FullUrl.Length)) -NoNewline
Write-Host "║"
Write-Host "║  Tokens: $Tokens  |  Duration: $Duration  |  Normal: ${ConnNorm}c  |  Spike: ${ConnSpike}c" -NoNewline
Write-Host (" " * (66 - "Tokens: $Tokens  |  Duration: $Duration  |  Normal: ${ConnNorm}c  |  Spike: ${ConnSpike}c".Length)) -NoNewline
Write-Host "║"
Write-Host "╚══════════════════════════════════════════════════════════════════╝"

Test-SidecarHealthz
Test-AdmissionEngine
Test-HeaderSurvival
Test-MetricsEndpoints
Test-LoadNormal
Test-LoadSpike
Test-LoadRejection
Test-LoadNoTokens
Show-SidecarStats

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗"
Write-Host "║  Phase 6 Load Test Complete                                     ║"
Write-Host "║  Prometheus  : http://localhost:9090                            ║"
Write-Host "║  Grafana     : http://localhost:3000  (admin / rajomon)         ║"
Write-Host "║  Envoy Admin : http://localhost:9901                            ║"
Write-Host "╚══════════════════════════════════════════════════════════════════╝"
