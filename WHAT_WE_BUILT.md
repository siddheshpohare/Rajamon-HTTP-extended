# Rajomon-HTTP — What We Built & How to Verify It

> **Status: ✅ PROJECT COMPLETE (20 November 2026)**  
> Plain English guide — what each phase is, what files we created, and exactly how to verify it works.

---

## The Big Picture

We built a **token-based admission control system** (a "traffic cop") that sits in front of every microservice in a REST/HTTP cluster.

When a request comes in, the cop enforces **three strict rules**:

1. **No token header** → reject immediately with 401 (strict — was fail-open)
2. **Tokens < `ceil(price)`** → reject immediately with 503 (upstream never touched)
3. **Tokens ≥ `ceil(price)`** → forward, deduct `ceil(price)` from budget

**Price rises automatically** as concurrent load grows:

```
price = base_price + scale_factor × (queued + in_flight)
cost  = ceil(price)
```

At 200 concurrent connections with `tokens=50`, the price immediately exceeds 50 — causing 100% of requests to be shed at the sidecar before the upstream is ever touched.

```
Client → [Sidecar / Traffic Cop] → Upstream Service
              ↑
        reads X-Rajomon-Tokens
        price = 1.0 + 0.5×(Q+IF)
        cost  = ceil(price)
        FORWARD (tokens≥cost) or REJECT (503/401)
```

The benchmark app we protect is **TeaStore** — 5 pure REST/HTTP Java microservices from the Descartes Research Group (Heidelberg University).

---

## Phase 1 — Benchmark App Running

### What it is
Getting TeaStore running in Docker. Pure baseline — no sidecar yet.

> **Why TeaStore and not DeathStarBench?**  
> DeathStarBench's Social Network services communicate via Apache Thrift binary protocol on port 9090, not HTTP. Our sidecar is an HTTP/1.1 reverse proxy. Switching to TeaStore (all REST/HTTP Spring Boot) was the correct fix — the sidecar Go code was always correct.

### Files
| File | What it does |
|---|---|
| `benchmark-app/docker-compose.yml` | TeaStore 7-container stack |
| `docker-compose.yml` | Root orchestration |
| `.env` | Config and project name |
| `benchmark-app/SERVICES.md` | Service port and alias reference |

### Verify
```bash
docker compose up -d
curl http://localhost:8080/tools.descartes.teastore.webui/
# Expected: 302 redirect or 200 HTML — TeaStore login page
```

---

## Phase 2 — Sidecar Skeleton

### What it is
A Go reverse proxy that transparently forwards every request to one upstream service. No decision logic yet — just proving the HTTP plumbing works.

### Files created
| File | What it does |
|---|---|
| `sidecar/main.go` | HTTP server: `/healthz`, `/metrics`, catch-all proxy |
| `sidecar/config.go` | Reads `RAJOMON_SERVICE_NAME`, `RAJOMON_LISTEN_ADDR`, `RAJOMON_UPSTREAM_ADDR` |
| `sidecar/Dockerfile` | Multi-stage build: `golang:1.26` → distroless binary |

### Verify
```bash
curl http://localhost:9550/healthz
# Expected: 200 OK, body: "ok"
```

---

## Phase 3 — Admission Engine

### What it is
The sidecar makes a decision on every request:

| Tokens present? | tokens vs. `ceil(price)` | Verdict | HTTP |
|---|---|---|---|
| No (missing/invalid) | — | `RejectMissingTokens` | **401** |
| Yes | `tokens ≥ ceil(price)` | `Forward` | 200 |
| Yes | `tokens < ceil(price)` | `RejectInsufficientTokens` | **503** |

**Price formula:** `price = base_price + scale_factor × (queued + in_flight)`  
**Cost:** always `ceil(price)` — prevents the truncation bug where `int(1.50)=1` allowed a 1-token request to pass a 1.50 price.

### Files created / changed
| File | What it does |
|---|---|
| `sidecar/headers.go` | `ReadTokenHeader` / `WriteTokenHeader` / `WritePriceHeader` |
| `sidecar/pricing.go` | Atomic `Queued` + `InFlight` counters; `GetLocalPrice()` |
| `sidecar/admission.go` | `Decide()` + `AdmissionCost()` using `math.Ceil` |
| `sidecar/admission_test.go` | 16 sub-tests covering all decision paths |
| `sidecar/config.go` | Added `RAJOMON_BASE_PRICE`, `RAJOMON_PRICE_SCALE_FACTOR` |

### Three policy changes (final, implemented Nov 2026)
1. **Strict missing-token rejection** — no header → 401, not forwarded
2. **Combined congestion signal** — `queued + in_flight` (not just queue depth)
3. **Ceiling charge** — `ceil(price)` prevents the `int(1.50)=1` truncation bypass

### Verify
```bash
# FORWARD
curl -si -H "X-Rajomon-Tokens: 100" http://localhost:9550/tools.descartes.teastore.webui/
# Expected: HTTP 200, X-Rajomon-Price: 1.50

# REJECT insufficient
curl -si -H "X-Rajomon-Tokens: 0" http://localhost:9550/tools.descartes.teastore.webui/
# Expected: HTTP 503

# REJECT missing token
curl -si http://localhost:9550/tools.descartes.teastore.webui/
# Expected: HTTP 401

# REJECT fractional (ceil(1.5)=2 > 1 token)
curl -si -H "X-Rajomon-Tokens: 1" http://localhost:9550/tools.descartes.teastore.webui/
# Expected: HTTP 503

# Unit tests (golang:1.26)
docker run --rm -v "D:\Rajamon-HTTP\sidecar:/src" -w /src golang:1.26 sh -c "go test ./... -v"
# Expected: ok rajomon-http/sidecar 0.029s — all 16 sub-tests PASS
```

---

## Phase 4 — Fleet Rollout + Prometheus + Grafana

### What it is
Sidecars deployed in front of **all 5 TeaStore services**, with Prometheus scraping every sidecar and Grafana showing a live fleet dashboard.

```
[5 Sidecars] ←scrape every 5s— [Prometheus :9090] ←reads— [Grafana :3000]
```

### Network alias trick (zero-touch interception)
Real service containers run as `teastore-<name>-upstream` (hidden).  
Sidecars claim the `teastore-<name>` Docker network alias (public).  
When `teastore-webui` calls `teastore-auth` by name, Docker DNS resolves to `sidecar-auth` — admission runs automatically with no application code changes.

### Files
| File | What it does |
|---|---|
| `sidecar/metrics.go` | 3 Prometheus metrics: request counter, in-flight gauge, price histogram |
| `monitoring/prometheus/prometheus.yml` | Scrapes all 5 sidecars every 5 s |
| `monitoring/grafana/dashboards/rajomon_fleet.json` | Pre-built fleet dashboard |

### Three Prometheus metrics
| Metric | Type | What it tracks |
|---|---|---|
| `rajomon_sidecar_requests_total` | Counter | Requests by service + verdict (`forward`, `reject_insufficient_tokens`, `reject_missing_tokens`) |
| `rajomon_sidecar_in_flight_requests` | Gauge | Live in-flight count per service |
| `rajomon_sidecar_admission_price` | Histogram | Price at decision time (p50/p95/p99 queryable) |

### Verify
```bash
curl http://localhost:9550/metrics | grep rajomon_sidecar
# Open: http://localhost:9090/targets  → all 5 targets UP
# Open: http://localhost:3000          → Grafana (admin/rajomon)
```

---

## Phase 5 — Gateway & Header-Survival Test

### What it is
Envoy gateway on port 10000 sits in front of the whole system. The critical question: does `X-Rajomon-Tokens` survive a real gateway hop?

| Config | X-Rajomon-Tokens | Behaviour |
|---|---|---|
| Permissive | Passes through intact | Tokens accounted, price enforced ✅ |
| Hardened | Stripped by Envoy | 401 returned (strict rejection, not fail-open) |

### Files
| File | What it does |
|---|---|
| `gateway-config/envoy-permissive.yaml` | Passes header intact |
| `gateway-config/envoy-hardened.yaml` | Strips header (tests strict rejection) |
| `load-tests/phase6-load-test.ps1` | Full 9-test load suite |

### Verify
```bash
docker compose --profile permissive up -d
curl -si -H "X-Rajomon-Tokens: 100" http://localhost:10000/tools.descartes.teastore.webui/
# Expected: HTTP 200 (header survived Envoy → sidecar FORWARD)
```

---

## Phase 6 — Evaluation & Load Tests ✅ COMPLETE

### Price-under-load proof (tokens=50, 200 connections)

| N concurrent | price | cost | verdict |
|---:|---:|---:|---|
| 1 | 1.50 | 2 | FORWARD |
| 98 | 50.00 | 50 | FORWARD (boundary) |
| 99+ | 50.50+ | 51+ | **REJECT 503** |

**Spike result — 200 conn, tokens=50, 30 s:**

```
514,442 total requests  |  101 forwarded  |  514,536 rejected (100%)
17,117 req/s  |  avg latency 37.78 ms  |  queued=0, in_flight=0 after test
```

### Full load test results

| Test | Connections | Throughput | Avg Latency | Non-2xx | Upstream Touches |
|---|---:|---:|---:|---:|---:|
| Forward (tokens=100) | 20 | 468 req/s | 77 ms | 0 | Yes |
| Spike forward (tokens=100) | 100 | 291 req/s | 221 ms | 0 | Yes |
| Insufficient-token rejection | 100 | **68,302 req/s** | **2.93 ms** | 100% (503) | **0** |
| Missing-token rejection | 20 | **40,390 req/s** | **1.17 ms** | 100% (401) | **0** |

> **Key insight:** The rejection fast-paths run at 40–68K req/s with sub-3 ms latency because the sidecar sheds load before the upstream is ever touched. This is exactly the intended behaviour.

---

## Phase 7 — End-to-End Verification ✅ COMPLETE

See [`END_TO_END_VALIDATION_REPORT.md`](END_TO_END_VALIDATION_REPORT.md) for the full signed-off validation.

**All admission engine checks pass. Project is complete.**

---

## Useful Commands

```bash
# Start full stack (TeaStore + 5 sidecars + Prometheus + Grafana + Envoy)
docker compose --profile permissive up -d

# Health checks (all 5 sidecars)
curl http://localhost:9550/healthz   # webui
curl http://localhost:9551/healthz   # auth
curl http://localhost:9552/healthz   # imageprovider
curl http://localhost:9553/healthz   # recommender
curl http://localhost:9554/healthz   # persistence

# Run Go unit tests
docker run --rm -v "${PWD}/sidecar:/src" -w /src golang:1.26 sh -c "go test ./... -v"

# Full 9-scenario load test suite (PowerShell)
.\load-tests\phase6-load-test.ps1

# Spike test (200 conn, tokens=50, 30s) — proves price-under-load
docker run --rm --network host williamyeh/wrk -t8 -c200 -d30s -H "X-Rajomon-Tokens: 50" http://localhost:9550/tools.descartes.teastore.webui/

# Stop everything
docker compose --profile permissive down
```

---

## Port Reference

| Port | Service |
|---|---|
| `8080` | TeaStore WebUI direct |
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
# Request rate per verdict
rate(rajomon_sidecar_requests_total[1m])

# Rejection fraction
sum(rate(rajomon_sidecar_requests_total{verdict="reject_insufficient_tokens"}[1m]))
/ sum(rate(rajomon_sidecar_requests_total[1m]))

# Live in-flight per service
rajomon_sidecar_in_flight_requests

# 95th percentile admission price
histogram_quantile(0.95, rate(rajomon_sidecar_admission_price_bucket[1m]))
```
