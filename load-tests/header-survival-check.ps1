# =============================================================================
# load-tests/header-survival-check.ps1
#
# Phase 5: Header-Survival Test (PowerShell / Windows native version)
#
# PURPOSE
# -------
# Windows-native equivalent of header-survival-check.sh.
# Tests whether X-Rajomon-Tokens survives a real Envoy gateway hop.
#
# USAGE
# -----
#   # Start the stack with a profile first, then run this script:
#   docker compose --profile permissive up -d
#   .\load-tests\header-survival-check.ps1 -Config permissive
#
#   docker compose --profile hardened up -d
#   .\load-tests\header-survival-check.ps1 -Config hardened
#
#   # Run both in sequence (starts containers automatically):
#   .\load-tests\header-survival-check.ps1 -Config both
# =============================================================================

param(
    [ValidateSet("permissive", "hardened", "both")]
    [string]$Config = "both"
)

$GatewayUrl   = "http://localhost:10000/survival-test"
$TokenValue   = "100"
$SidecarSvc   = "sidecar-compose-post"
$ResultsFile  = "evaluation-results.md"

function Record-Result {
    param(
        [string]$ConfigName,
        [string]$Result,
        [string]$Detail
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "| $ConfigName | $Result | $Detail | $ts |"
    if (Test-Path $ResultsFile) {
        Add-Content -Path $ResultsFile -Value $line
    }
}

function Invoke-HeaderCheck {
    param([string]$ConfigName)

    Write-Host ""
    Write-Host "=============================================================="
    Write-Host "  Header-Survival Check -- config: $ConfigName"
    Write-Host "=============================================================="

    # Step 1: Send a request through the gateway with the token header
    Write-Host "  [1] Sending GET $GatewayUrl with X-Rajomon-Tokens: $TokenValue"
    $httpStatus = 0
    try {
        $resp = Invoke-WebRequest -Uri $GatewayUrl `
            -Headers @{ "X-Rajomon-Tokens" = $TokenValue } `
            -UseBasicParsing -ErrorAction Stop
        $httpStatus = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) {
            $httpStatus = [int]$_.Exception.Response.StatusCode
        } else {
            Write-Host "  ERROR: Could not reach gateway at $GatewayUrl" -ForegroundColor Red
            Write-Host "         Is 'docker compose --profile $ConfigName up -d' running?"
            return
        }
    }
    Write-Host "  [1] HTTP response status: $httpStatus"

    # Step 2: Read sidecar logs
    Start-Sleep -Milliseconds 600
    Write-Host "  [2] Reading last 30 lines of ${SidecarSvc} logs..."
    $logs = docker compose logs --no-log-prefix --tail=30 $SidecarSvc 2>$null

    # Step 3: Detect verdict from logs
    $verdict = "UNKNOWN"
    if ($logs -match "FORWARD.*tokens=$TokenValue") {
        $verdict = "FORWARD"
    } elseif ($logs -match "FAIL-OPEN.*survival-test") {
        $verdict = "FAIL-OPEN"
    } elseif ($logs -match "FAIL-OPEN") {
        $verdict = "FAIL-OPEN"
    }
    Write-Host "  [2] Sidecar log verdict detected: $verdict"
    Write-Host ""

    # Step 4: Evaluate
    switch ($ConfigName) {
        "permissive" {
            if ($verdict -eq "FORWARD") {
                Write-Host "  PASS -- X-Rajomon-Tokens survived the permissive gateway hop." -ForegroundColor Green
                Write-Host "         Header arrived intact. Admission ran with tokens=$TokenValue. HTTP $httpStatus."
                Record-Result -ConfigName "permissive" -Result "PASS" `
                    -Detail "X-Rajomon-Tokens survived. Sidecar log shows FORWARD with tokens=$TokenValue. HTTP $httpStatus."
            } else {
                Write-Host "  FAIL -- X-Rajomon-Tokens unexpectedly dropped by permissive gateway." -ForegroundColor Red
                Write-Host "         Sidecar verdict: $verdict. This is unexpected."
                Record-Result -ConfigName "permissive" -Result "FAIL (unexpected)" `
                    -Detail "Header dropped by permissive config. Sidecar verdict: $verdict. HTTP $httpStatus."
            }
        }
        "hardened" {
            if ($verdict -eq "FAIL-OPEN") {
                Write-Host "  FAIL (expected) -- X-Rajomon-Tokens was stripped by the hardened gateway." -ForegroundColor Yellow
                Write-Host "         Sidecar verdict: FAIL-OPEN -- system degraded safely, request completed."
                Write-Host "         HTTP status $httpStatus -- no crash, no hang. Fail-open confirmed." -ForegroundColor Green
                Record-Result -ConfigName "hardened" -Result "FAIL (expected -- header stripped)" `
                    -Detail "Header stripped. Sidecar FAIL-OPEN: request completed safely. HTTP $httpStatus. Fail-open confirmed."
            } else {
                Write-Host "  UNEXPECTED -- Hardened gateway did NOT strip the header." -ForegroundColor Red
                Write-Host "         Sidecar verdict: $verdict. Expected FAIL-OPEN."
                Record-Result -ConfigName "hardened" -Result "UNEXPECTED PASS" `
                    -Detail "Header survived hardened config unexpectedly. Sidecar verdict: $verdict. HTTP $httpStatus."
            }
        }
    }
    Write-Host ""
}

switch ($Config) {
    "permissive" {
        Invoke-HeaderCheck "permissive"
    }
    "hardened" {
        Invoke-HeaderCheck "hardened"
    }
    "both" {
        Write-Host "Testing permissive gateway..."
        docker compose --profile permissive up -d 2>$null
        Start-Sleep -Seconds 2
        Invoke-HeaderCheck "permissive"

        Write-Host "Switching to hardened gateway..."
        docker compose --profile permissive down 2>$null
        docker compose --profile hardened up -d 2>$null
        Start-Sleep -Seconds 2
        Invoke-HeaderCheck "hardened"
    }
}

Write-Host "=============================================================="
Write-Host "  Header-survival check complete."
Write-Host "  Results recorded in $ResultsFile."
Write-Host "=============================================================="
