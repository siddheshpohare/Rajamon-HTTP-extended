# Rajamon-HTTP

**HTTP-layer admission control for microservices — COL724/COL7524**  
Suraj Raj (2026MCS2801) · Siddhesh Pohare (2026MCS2257) · August–November 2026

> **Status: ✅ PROJECT COMPLETE (20 November 2026)**  
> See [`END_TO_END_VALIDATION_REPORT.md`](END_TO_END_VALIDATION_REPORT.md) for the full signed-off validation.

---

## What This Project Does

Rajomon-HTTP implements **token-based admission control** for REST/HTTP microservice clusters. Each service gets a lightweight Go **sidecar proxy**. When a request arrives the sidecar enforces three strict rules:

| Tokens present? | tokens vs. `ceil(price)` | Verdict | HTTP | Upstream? |
|---|---|---|---|---|
| No (missing/invalid) | — | `RejectMissingTokens` | **401** | No |
| Yes | tokens ≥ ceil(price) | `Forward` | 200 | Yes |
| Yes | tokens < ceil(price) | `RejectInsufficientTokens` | **503** | No |

**Price rises automatically with concurrent load:**

```
price = base_price + scale_factor × (queued + in_flight)
cost  = ceil(price)
```

Under a 200-connection spike with `tokens=50`, the price exceeds 50 within milliseconds — 514,536 requests were shed at the sidecar at 17K req/s before the upstream was ever touched.

---

## Why TeaStore (Not DeathStarBench)

DeathStarBench's Social Network services communicate internally via **Apache Thrift binary** on port 9090, not HTTP. Our sidecar is an HTTP/1.1 reverse proxy. Switching to TeaStore (all REST/HTTP Spring Boot) was the correct fix — the sidecar Go code was always correct.

| | DeathStarBench | TeaStore |
|---|---|---|
| Internal protocol | Apache Thrift binary | **REST/HTTP (Spring Boot)** |
| Sidecar compatible | ❌ Protocol mismatch | ✅ Direct match |
| Services | 11 | 5 business-logic services |

---

## Architecture

```
  Load Generator (wrk)
  GET /tools.descartes.teastore.webui/
  X-Rajomon-Tokens: 100
         │
         ▼
  ┌──────────────────────┐
  │  Envoy Gateway       │  :10000  (profile: permissive / hardened)
  └──────────┬───────────┘
             │ X-Rajomon-Tokens: 100
             ▼
  ┌──────────────────────────────────────────────────────┐
  │  sidecar-webui  :9550                                │
  │  price = 1.0 + 0.5×(Q+IF)   cost = ceil(price)      │
  │  FORWARD → X-Rajomon-Tokens: 98 (deducted ceil=2)   │
  └──────────┬───────────────────────────────────────────┘
             ▼
  ┌──────────────────────────┐
  │  teastore-webui  :8080   │  (Java Spring Boot, unmodified)
  └─────┬──────┬──────┬──────┘
        │      │      │  X-Rajomon-Tokens: 98 propagated
        ▼      ▼      ▼
  sidecar-auth  sidecar-imageprovider  sidecar-recommender  sidecar-persistence
        │
        ▼
  teastore-db (MariaDB)

  ◀──────── X-Rajomon-Price: 1.50 on all responses ────────

  ┌──────────────────┐     ┌────────────────────┐
  │  Prometheus :9090│────▶│  Grafana :3000      │
  │  scrapes 5 side- │     │  Fleet dashboard    │
  │  cars every 5s   │     │  p50/p95/p99 price  │
  └──────────────────┘     └────────────────────┘
```

### Network alias trick (zero application code changes)

Real containers run as `teastore-<name>-upstream` (hidden).  
Sidecars claim `teastore-<name>` as a Docker network alias.  
When `teastore-webui` calls `teastore-auth`, Docker DNS resolves to `sidecar-auth` — admission runs automatically.

---

## Repository Layout

```
Rajamon-HTTP/
├── benchmark-app/              # TeaStore benchmark
│   ├── docker-compose.yml      # 7-container TeaStore stack
│   └── SERVICES.md
│
├── sidecar/                    # Rajomon-HTTP sidecar (Go)
│   ├── main.go                 # /healthz, /metrics, catch-all admission+proxy
│   ├── config.go               # SidecarConfig + LoadConfigFromEnv()
│   ├── headers.go              # ReadTokenHeader / WriteTokenHeader / WritePriceHeader
│   ├── pricing.go              # Queued+InFlight counters + GetLocalPrice()
│   ├── admission.go            # Decide() + AdmissionCost() [math.Ceil]
│   ├── metrics.go              # Prometheus counters / gauge / histogram
│   ├── admission_test.go       # 16 unit tests — all decision paths
│   ├── go.mod
│   └── Dockerfile
│
├── monitoring/
│   ├── prometheus/prometheus.yml
│   └── grafana/dashboards/rajomon_fleet.json
│
├── gateway-config/
│   ├── envoy-permissive.yaml   # Passes X-Rajomon-Tokens intact
│   └── envoy-hardened.yaml     # Strips X-Rajomon-Tokens
│
├── load-tests/
│   ├── phase6-load-test.ps1    # Full 9-scenario load test suite
│   ├── spike-price-watch.lua   # wrk Lua script: watches price rise under spike
│   ├── teastore-baseline.lua
│   ├── teastore-rajomon.lua
│   └── teastore-spike.lua
│
├── docker-compose.yml
├── .env / .env.example
├── README.md                   ← you are here
├── WHAT_WE_BUILT.md            ← plain-English phase guide
└── END_TO_END_VALIDATION_REPORT.md  ← signed-off validation results
```

---

## Phase Progress

| # | Phase | Status | What was built |
|---|---|---|---|
| 1 | Environment & Benchmark Baseline | ✅ Done | TeaStore running via Docker Compose |
| 2 | Sidecar Skeleton | ✅ Done | Transparent Go reverse proxy |
| 3 | Admission Engine | ✅ Done | Token/price decision logic, strict policy |
| 4 | Fleet Rollout & Metrics | ✅ Done | 5 sidecars + Prometheus + Grafana |
| 5 | Gateway & Header-Survival Test | ✅ Done | Envoy permissive/hardened + header tests |
| 6 | Evaluation Harness & Load Tests | ✅ Done | Full load suite, price-under-load confirmed |
| 7 | End-to-End Verification | ✅ **COMPLETE** | All checks pass, report signed off |

---

## Three Policy Changes (Implemented Nov 2026)

| Change | Old behaviour | New behaviour |
|---|---|---|
| Missing token header | Fail-open → 200 forwarded | **Strict → 401 Unauthorized** |
| Congestion signal | Queue depth only | **Queue + in-flight** |
| Token charge | `int(price)` truncates | **`ceil(price)`** — prevents bypass |

---

## Quick Start

```bash
git clone https://github.com/siddheshpohare/Rajomon-HTTP.git
cd Rajomon-HTTP
cp .env.example .env

# Start everything: TeaStore + 5 sidecars + Prometheus + Grafana + Envoy
docker compose --profile permissive up -d

# Wait ~60s for TeaStore JVM to warm up, then:

# Verify sidecar health (all 5)
curl http://localhost:9550/healthz   # webui  → 200 ok
curl http://localhost:9551/healthz   # auth
curl http://localhost:9552/healthz   # imageprovider
curl http://localhost:9553/healthz   # recommender
curl http://localhost:9554/healthz   # persistence

# FORWARD — tokens=100 ≥ ceil(1.50)=2
curl -si -H "X-Rajomon-Tokens: 100" http://localhost:9550/tools.descartes.teastore.webui/
# → HTTP 200   X-Rajomon-Price: 1.50

# REJECT insufficient
curl -si -H "X-Rajomon-Tokens: 0" http://localhost:9550/tools.descartes.teastore.webui/
# → HTTP 503

# REJECT missing token (strict — no fail-open)
curl -si http://localhost:9550/tools.descartes.teastore.webui/
# → HTTP 401

# REJECT fractional (ceil(1.5)=2 > tokens=1)
curl -si -H "X-Rajomon-Tokens: 1" http://localhost:9550/tools.descartes.teastore.webui/
# → HTTP 503

# Envoy header survival
curl -si -H "X-Rajomon-Tokens: 100" http://localhost:10000/tools.descartes.teastore.webui/
# → HTTP 200   (header survived gateway hop)
```

---

## Running Unit Tests

```bash
# No local Go needed — runs in a disposable container
docker run --rm -v "${PWD}/sidecar:/src" -w /src golang:1.26 sh -c "go test ./... -v"
# Expected: ok  rajomon-http/sidecar  0.029s  — all 16 sub-tests PASS
```

---

## Load Tests

```bash
# Full 9-scenario suite (PowerShell)
.\load-tests\phase6-load-test.ps1

# Spike: 200 connections, tokens=50, 30s — proves price-under-load rejection
docker run --rm --network host williamyeh/wrk \
  -t8 -c200 -d30s \
  -H "X-Rajomon-Tokens: 50" \
  http://localhost:9550/tools.descartes.teastore.webui/
# Expected: ~100% Non-2xx (503) — price exceeds 50-token budget immediately

# Fast rejection path: tokens=1 (below ceil(1.5)=2)
docker run --rm --network host williamyeh/wrk \
  -t4 -c100 -d30s \
  -H "X-Rajomon-Tokens: 1" \
  http://localhost:9550/tools.descartes.teastore.webui/
# Expected: ~68K req/s, 2.93 ms avg latency, 100% 503
```

---

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `RAJOMON_BASE_PRICE` | `1.0` | Minimum admission price (all sidecars) |
| `RAJOMON_PRICE_SCALE_FACTOR` | `0.5` | Price increase per concurrent request |
| `GF_SECURITY_ADMIN_PASSWORD` | `rajomon` | Grafana admin password |
| `ENVOY_GATEWAY_PORT` | `10000` | Envoy gateway host port |

---

## Port Reference

| Port | Service |
|---|---|
| `8080` | TeaStore WebUI direct |
| `8083` | TeaStore Registry API |
| `9550` | sidecar-webui |
| `9551` | sidecar-auth |
| `9552` | sidecar-imageprovider |
| `9553` | sidecar-recommender |
| `9554` | sidecar-persistence |
| `10000` | Envoy gateway |
| `9901` | Envoy admin UI |
| `9090` | Prometheus |
| `3000` | Grafana (admin / rajomon) |
| `3306` | MariaDB (internal) |

---

## Useful PromQL Queries

```promql
# Request rate by verdict
rate(rajomon_sidecar_requests_total[1m])

# Rejection fraction
sum(rate(rajomon_sidecar_requests_total{verdict="reject_insufficient_tokens"}[1m]))
/ sum(rate(rajomon_sidecar_requests_total[1m]))

# Live in-flight per service
rajomon_sidecar_in_flight_requests

# 95th-percentile admission price
histogram_quantile(0.95, rate(rajomon_sidecar_admission_price_bucket[1m]))
```

---

## Day-to-Day Commands

```bash
# Start full stack
docker compose --profile permissive up -d

# Check containers
docker compose --profile permissive ps

# Watch sidecar logs live
docker compose logs -f sidecar-webui

# Stop everything
docker compose --profile permissive down

# Nuclear reset
docker compose --profile permissive down -v && docker compose --profile permissive up -d
```
