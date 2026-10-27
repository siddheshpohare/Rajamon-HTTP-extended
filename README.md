# Rajamon-HTTP

**HTTP-layer admission control for microservices — COL724/COL7524**  
Suraj Raj (2026MCS2801) · Siddhesh Pohare (2026MCS2257) · August 2026

> See `phase_guide.txt` for the original step-by-step build plan, and `context_doc.txt` for the design rationale.

---

## What This Project Does

Rajomon-HTTP implements a **token-based admission control mechanism** for microservice clusters. Each service gets a lightweight **sidecar proxy** sitting in front of it. When a request arrives, the sidecar:

1. Reads a token budget from the `X-Rajomon-Tokens` request header
2. Computes a **local price** based on current in-flight load
3. **Forwards** the request (deducting price from tokens) if affordable, or **rejects with 503** if not — protecting the service from overload

This is a REST/HTTP port of the Rajomon mechanism (originally implemented for gRPC/Thrift). The benchmark target is **TeaStore** — a 5-service, pure REST/HTTP microservice application from the Descartes Research Group.

---

## Why TeaStore (Not DeathStarBench)

> **Root cause:** DeathStarBench's Social Network services communicate internally via **Apache Thrift binary protocol** on port 9090, not HTTP. Our sidecar is an HTTP/1.1 reverse proxy. When the sidecar forwarded requests into `compose-post-service:9090`, the Thrift binary frame was interpreted as HTTP — causing an immediate connection close.
>
> Fixing this would require modifying DSB's containers (violating the zero-application-code-change guarantee). **Switching benchmarks is the correct fix.**

| | DeathStarBench | TeaStore |
|-|----------------|----------|
| Internal protocol | Apache Thrift binary | **REST/HTTP (Java Spring Boot)** |
| Sidecar compatible | ❌ Protocol mismatch | ✅ Direct match |
| Docker Compose | ✅ | ✅ |
| Multi-service topology | 11 services | **5 business-logic services** |
| Academic use | CMU/Alibaba cited | Descartes Research Group, widely cited |

The **sidecar Go source (`sidecar/*.go`) is completely unchanged** — it was always correct. Only the benchmark and orchestration config changed.

---

## Architecture

```
  Load Generator (wrk2)
  GET /tools.descartes.teastore.webui/
  X-Rajomon-Tokens: 100
         │
         ▼
  ┌──────────────────────┐
  │  Envoy Gateway       │  :10000
  │  permissive: passes  │
  │  hardened:   strips  │
  └──────────┬───────────┘
             │ X-Rajomon-Tokens: 100
             ▼
  ┌──────────────────────────────────────────────────────┐
  │  sidecar-webui  :9550                                │
  │  reads tokens=100, price=1.0 (low load)              │
  │  verdict: FORWARD → writes X-Rajomon-Tokens: 99      │
  └──────────┬───────────────────────────────────────────┘
             │ HTTP :8080
             ▼
  ┌──────────────────────────┐
  │  teastore-webui  :8080   │  (Java Spring Boot, unmodified)
  │  makes REST calls to:    │
  └─────┬──────┬──────┬──────┘
        │      │      │  X-Rajomon-Tokens: 99 propagated on each call
        ▼      ▼      ▼
  ┌──────┐ ┌──────┐ ┌───────────┐
  │side- │ │side- │ │sidecar-   │
  │car-  │ │car-  │ │recommender│
  │auth  │ │img   │ │  :9553    │
  │:9551 │ │:9552 │ └─────┬─────┘
  └──┬───┘ └──┬───┘       │
     │        │           ▼
     │        │     ┌──────────────┐
     │        │     │sidecar-      │
     │        │     │persistence   │
     │        │     │   :9554      │
     │        │     └──────┬───────┘
     │        │            │
     ▼        ▼            ▼
  teastore-auth  teastore-imageprovider  teastore-recommender
  teastore-persistence  →  teastore-db (MariaDB)

  ◀────────────── X-Rajomon-Price on all responses ──────────────────

  ┌──────────────────┐     ┌────────────────────┐
  │  Prometheus      │────▶│  Grafana            │
  │  :9090           │     │  :3000              │
  │  scrapes 5 side- │     │  Fleet dashboard    │
  │  cars every 5s   │     │  (p50/p95/p99,      │
  └──────────────────┘     │   goodput, prices)  │
                           └────────────────────┘
```

### Network Alias Trick (Zero-Touch Interception)

Real service containers run as `teastore-<name>-upstream` (hidden).  
Sidecar containers claim the `teastore-<name>` Docker network alias (public).  
When `teastore-webui` makes a REST call to `teastore-auth`, Docker DNS resolves to `sidecar-auth` — admission runs automatically. No application code changes.

---

## Repository Layout

```
Rajamon-HTTP/
├── benchmark-app/              # TeaStore benchmark (REST/HTTP — Phase B)
│   ├── docker-compose.yml      # TeaStore 7-container stack (registry, db, 5 services)
│   └── SERVICES.md             # Service reference: ports, sidecar assignments, alias map
│
├── sidecar/                    # Rajomon-HTTP sidecar — Go reverse proxy (UNCHANGED)
│   ├── main.go                 # HTTP server: /healthz, /metrics, catch-all admission+proxy
│   ├── config.go               # SidecarConfig + LoadConfigFromEnv()
│   ├── headers.go              # ReadTokenHeader / WriteTokenHeader / WritePriceHeader
│   ├── pricing.go              # InFlight counter + GetLocalPrice()
│   ├── admission.go            # Decide() — Decision Table (Forward/Reject/FailOpen)
│   ├── metrics.go              # SidecarMetrics — Prometheus counters/gauge/histogram
│   ├── admission_test.go       # Unit tests — all Decision Table rows
│   ├── go.mod
│   └── Dockerfile
│
├── monitoring/
│   ├── prometheus/
│   │   └── prometheus.yml      # Scrapes 5 TeaStore sidecars every 5s
│   └── grafana/
│       ├── provisioning/       # Auto-wired datasource + dashboard provider
│       └── dashboards/
│           └── rajomon_fleet.json
│
├── gateway-config/
│   ├── envoy-permissive.yaml   # Passes X-Rajomon-Tokens intact → sidecar-webui:9550
│   └── envoy-hardened.yaml     # Strips X-Rajomon-Tokens → tests fail-open degradation
│
├── load-tests/
│   ├── teastore-baseline.lua   # wrk2: no tokens, direct to :8080 (baseline)
│   ├── teastore-rajomon.lua    # wrk2: X-Rajomon-Tokens via gateway (Rajomon active)
│   ├── teastore-spike.lua      # wrk2: bursty load spike — core evaluation scenario
│   ├── header-survival-check.ps1
│   └── header-survival-check.sh
│
├── docker-compose.yml          # Root orchestration: TeaStore + 5 sidecars + monitoring + Envoy
├── .env.example                # All tunable env vars with defaults
└── README.md
```

---

## Phase Progress

| # | Phase | Status | What was built |
|---|-------|--------|----------------|
| 1 | Environment & Benchmark Baseline | ✅ **Done** | TeaStore running via Docker Compose (replaced DSB Social Network) |
| 2 | Sidecar Skeleton | ✅ **Done** | Transparent Go reverse proxy on `sidecar-webui` |
| 3 | Admission Engine | ✅ **Done** | Token/price decision logic active on all 5 sidecars |
| 4 | Fleet Rollout & Metrics | ✅ **Done** | 5 sidecars + Prometheus + Grafana fleet dashboard |
| 5 | Gateway & Header-Survival Test | ✅ **Done** | Envoy (permissive & hardened) + header-survival scripts |
| 6 | Evaluation Harness | ⏳ Next | wrk2 load tests: baseline vs. Rajomon spike comparison |
| 7 | End-to-End Verification | ⏳ Later | Full evaluation report + results |

---

## Sidecar Decision Table

| Tokens present & valid? | Tokens vs. price | Verdict | Upstream touched? |
|------------------------|-----------------|---------|------------------|
| No | — | `ForwardFailOpen` | Yes |
| Yes | tokens ≥ price | `Forward` | Yes |
| Yes | tokens < price | `RejectInsufficientTokens` | No (503 returned immediately) |

Token flow: `X-Rajomon-Tokens` travels **forward** on the request (remaining budget).  
Price flow: `X-Rajomon-Price` travels **back** on the response (congestion signal).

---

## Quick Start

```bash
git clone https://github.com/siddheshpohare/Rajamon-HTTP.git
cd Rajamon-HTTP
cp .env.example .env

# Start everything: TeaStore + 5 sidecars + Prometheus + Grafana
docker compose up -d --build

# Verify TeaStore entry point (direct, no sidecar)
curl http://localhost:8080/tools.descartes.teastore.webui/

# Verify sidecar-webui health
curl http://localhost:9550/healthz

# Send a token-bearing request through sidecar-webui
curl -H "X-Rajomon-Tokens: 100" http://localhost:9550/tools.descartes.teastore.webui/

# Check sidecar metrics (Prometheus format)
curl http://localhost:9550/metrics | grep rajomon

# Open Prometheus targets (all 5 sidecars should be UP)
start http://localhost:9090/targets

# Open Grafana fleet dashboard
start http://localhost:3000
```

### Gateway Tests (Phase 5)

```bash
# PASS test — tokens survive Envoy
docker compose --profile permissive up -d
.\load-tests\header-survival-check.ps1

# FAIL test — tokens stripped by hardened Envoy
docker compose --profile permissive down
docker compose --profile hardened up -d
.\load-tests\header-survival-check.ps1
```

### Load Tests (Phase 6)

```bash
# Baseline — no admission control, direct to TeaStore
wrk2 -t 4 -c 50 -d 60s -R 200 \
  --script load-tests/teastore-baseline.lua \
  http://localhost:8080

# Rajomon-HTTP active — via gateway + sidecars
wrk2 -t 4 -c 50 -d 60s -R 200 \
  --script load-tests/teastore-rajomon.lua \
  http://localhost:10000

# Spike scenario — the core evaluation test
wrk2 -t 4 -c 200 -d 90s -R 500 \
  --script load-tests/teastore-spike.lua \
  http://localhost:10000
```

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `COMPOSE_PROJECT_NAME` | `rajomon-http` | Namespaces Docker container/network names |
| `RAJOMON_BASE_PRICE` | `1.0` | Minimum admission price — applies to ALL sidecars |
| `RAJOMON_PRICE_SCALE_FACTOR` | `0.5` | Price increase per in-flight request |
| `GF_SECURITY_ADMIN_PASSWORD` | `rajomon` | Grafana admin password |
| `ENVOY_GATEWAY_PORT` | `10000` | Envoy gateway host port |

---

## Port Reference

| Port | Service |
|------|---------|
| `8080` | TeaStore WebUI (direct — no sidecar) |
| `8083` | TeaStore Registry API |
| `9550` | `sidecar-webui` |
| `9551` | `sidecar-auth` |
| `9552` | `sidecar-imageprovider` |
| `9553` | `sidecar-recommender` |
| `9554` | `sidecar-persistence` |
| `10000` | Envoy Gateway |
| `9901` | Envoy Admin UI |
| `9090` | Prometheus |
| `3000` | Grafana |
| `3306` | MariaDB (internal) |

---

## Day-to-Day Commands

```bash
# Start full stack
docker compose up -d --build

# Check all containers
docker compose ps

# View sidecar logs live
docker compose logs -f sidecar-webui
docker compose logs -f sidecar-persistence

# Run Go unit tests (no local Go needed)
docker compose run --rm sidecar-webui go test ./...

# Stop everything
docker compose down

# Nuclear reset
docker compose down -v && docker compose up -d --build
```
