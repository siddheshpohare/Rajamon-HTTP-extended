# Rajamon-HTTP

**HTTP-layer admission control for microservices — COL724/COL7524**
Suraj Raj (2026MCS2801) · Siddhesh Pohare (2026MCS2257) · Draft — August 2026

> See `phase_guide.txt` for the full step-by-step build plan, and `context_doc.txt` for the design rationale.

---

## What This Project Does

Rajomon-HTTP implements a **token-based admission control mechanism** for microservice clusters. Each service gets a lightweight **sidecar proxy** sitting in front of it. When a request arrives, the sidecar:

1. Reads a token budget from the `X-Rajomon-Tokens` request header
2. Computes a **local price** based on current in-flight load
3. **Forwards** the request (deducting price from tokens) if affordable, or **rejects with 503** if not — protecting the service from overload

The benchmark target is DeathStarBench's **Social Network** application (11 microservices). The goal is to reproduce the paper's headline result: lower tail latency and higher goodput under load spikes, compared to an uncontrolled baseline.

---

## Repository Layout

```
Rajamon-HTTP/
├── benchmark-app/              # DeathStarBench Social Network (unmodified, Phase 1)
│   ├── docker-compose.yml      # Original DSB compose — 20 services, no changes allowed
│   ├── SERVICES.md             # Reference table: every service name + port (Phase 2+ sidecar config)
│   ├── config/                 # Service config files (jaeger, mongo, redis, service-config.json)
│   ├── nginx-web-server/       # OpenResty Lua scripts + nginx.conf (HTTP entry point on :8080)
│   ├── gen-lua/                # Thrift-generated Lua stubs used by nginx-thrift
│   ├── media-frontend/         # Media upload/download nginx frontend (:8081)
│   ├── docker/                 # Docker helpers (openresty-thrift Lua library, mcrouter)
│   └── ...                     # Source, datasets, wrk2 scripts, helm charts (from DSB upstream)
│
├── sidecar/                    # Rajomon-HTTP sidecar — Go reverse proxy (Phase 2+)
│   ├── main.go                 # HTTP server: /healthz, /metrics (Prometheus), catch-all admission+proxy
│   ├── config.go               # SidecarConfig struct + LoadConfigFromEnv() (Phase 3: BasePrice, PriceScaleFactor)
│   ├── headers.go              # ReadTokenHeader / WriteTokenHeader / WritePriceHeader (Phase 3)
│   ├── pricing.go              # Metrics{InFlight, pm} + GetLocalPrice() (Phase 3/4)
│   ├── admission.go            # Verdict type + Decide() — exact Decision Table (Phase 3)
│   ├── metrics.go              # SidecarMetrics — Prometheus counters/gauge/histogram (Phase 4)
│   ├── admission_test.go       # Unit tests — every Decision Table row (Phase 3)
│   ├── go.mod                  # Go module: rajomon-http/sidecar
│   └── Dockerfile              # Multi-stage build: golang:1.22 (go mod tidy+build) → distroless/static
│
├── monitoring/                 # Observability stack configuration (Phase 4)
│   ├── prometheus/
│   │   └── prometheus.yml      # Scrapes /metrics from all 11 sidecars every 5s
│   └── grafana/
│       ├── provisioning/
│       │   ├── datasources/prometheus.yml   # Auto-wires Prometheus as Grafana data source
│       │   └── dashboards/rajomon.yml       # Loads dashboards from /var/lib/grafana/dashboards
│       └── dashboards/
│           └── rajomon_fleet.json           # Pre-built fleet dashboard (req/s, rejections, price)
│
├── docker-compose.yml          # Root orchestration — grows one phase at a time
├── .env.example                # All tunable env vars with defaults + comments
├── .env                        # Local values (gitignored — never committed)
├── .gitignore
└── README.md                   # This file
```

---

## Phase Progress

| # | Phase | Status | What was built |
|---|-------|--------|----------------|
| 1 | Environment & Benchmark Baseline | ✅ **Done** | DSB Social Network running unmodified in Docker Compose |
| 2 | Sidecar Skeleton | ✅ **Done** | Transparent Go reverse proxy in front of `compose-post-service` |
| 3 | Admission Engine | ✅ **Done** | Token/price decision logic live on `compose-post-service` |
| 4 | Fleet Rollout & Metrics | ✅ **Done** | Sidecars on all 11 services + Prometheus + Grafana |
| 5 | Gateway & Header-Survival Test | ⏳ Later | Envoy gateway + header-survival test |
| 6 | Evaluation Harness | ⏳ Later | wrk2 load tests + Grafana dashboards |
| 7 | End-to-End Verification | ⏳ Later | Full manual walkthrough |

---

## Phase 1 — Environment & Benchmark Baseline

**Goal:** Get DeathStarBench's Social Network running, unmodified, entirely in Docker Compose.
This is the ground truth baseline every later phase compares against.

### What was done
- Cloned `https://github.com/delimitrou/DeathStarBench` and copied the `socialNetwork/` directory into `benchmark-app/`
- The `benchmark-app/docker-compose.yml` is the **original DSB compose file, unmodified** (per the phase guide — no changes allowed)
- Root `docker-compose.yml` uses `include:` to pull it in
- Created `benchmark-app/SERVICES.md` — a reference table of every service name and internal port, used by all later phases
- Configured `.env` with `COMPOSE_PROJECT_NAME=rajomon-http` and `SOCIAL_NETWORK_NGINX_PORT=8080`

### Services started (27 containers)

| Category | Services |
|----------|----------|
| **Entry points** | `nginx-thrift` (:8080), `media-frontend` (:8081) |
| **Microservices** | `compose-post`, `social-graph`, `user`, `user-timeline`, `home-timeline`, `post-storage`, `url-shorten`, `media`, `text`, `unique-id`, `user-mention` |
| **Databases** | 5× MongoDB, 3× Redis, 3× Memcached |
| **Observability** | Jaeger all-in-one (:16686) |

### Exit conditions verified
- ✅ `docker compose ps` — all 27 containers `Up`, zero crash-restart loops
- ✅ `curl http://localhost:8080/` → HTTP 200 (Social Network login page)
- ✅ `benchmark-app/SERVICES.md` — real service names and ports, not placeholders
- ✅ Commit: `[Phase 1] Environment & Benchmark Baseline -- Social Network app runs unmodified via Docker Compose`

---

## Phase 2 — Sidecar Skeleton

**Goal:** A Rajomon-HTTP sidecar deployed in front of exactly one service (`compose-post-service`).
It does **nothing but transparently proxy** every request through — no token/price logic yet.
This phase proves the plumbing (proxy pattern, Docker wiring, container networking) works
before any decision logic is added on top in Phase 3.

### What was built

#### `sidecar/config.go`
Defines `SidecarConfig` with three fields and `LoadConfigFromEnv()` which reads:

| Env var | Example value | Purpose |
|---------|--------------|---------| 
| `RAJOMON_SERVICE_NAME` | `compose-post-service` | Identifies this sidecar in logs |
| `RAJOMON_LISTEN_ADDR` | `:9464` | Port the sidecar listens on |
| `RAJOMON_UPSTREAM_ADDR` | `compose-post-service:9090` | Where traffic is forwarded |

If any of the three is missing, the process logs the missing names and exits non-zero immediately.

#### `sidecar/main.go`
Starts an HTTP server on `RAJOMON_LISTEN_ADDR` with three routes:

| Route | Behaviour |
|-------|-----------|
| `GET /healthz` | Returns `200 OK` with body `ok` |
| `GET /metrics` | Returns `200 OK` with empty body (placeholder — real Prometheus metrics in Phase 4) |
| `/*` (catch-all) | Logs the request, then reverse-proxies it to `RAJOMON_UPSTREAM_ADDR` unchanged using Go's `net/http/httputil.ReverseProxy` |

#### `sidecar/Dockerfile`
Multi-stage build:
- **Stage 1** (`golang:1.22`): compiles a fully static binary (`CGO_ENABLED=0`)
- **Stage 2** (`gcr.io/distroless/static:nonroot`): copies in only the binary — no shell, no Go toolchain, minimal attack surface

#### `docker-compose.yml` (root)
Added `sidecar-compose-post` service:
- Built from `./sidecar/Dockerfile`
- Exposes port `9464` on the host
- Shares the same Docker network as `benchmark-app/` services so it can reach `compose-post-service` by container name
- `depends_on: compose-post-service`

### Exit conditions verified
- ✅ `curl http://localhost:9464/healthz` → `200 OK`
- ✅ Same request sent directly to `compose-post-service` and through the sidecar returns identical response
- ✅ `docker compose logs sidecar-compose-post` shows a log line for every proxied request
- ✅ Commit: `[Phase 2] Sidecar Skeleton -- transparent pass-through proxy live in front of compose-post-service`

---

## Phase 3 — Admission Engine

**Goal:** The sidecar in front of `compose-post-service` makes a real admission decision on every
request — **forward or reject with 503** — based on tokens attached to the request and a
live, locally-computed price. This is the heart of the entire project (Context Document A§8).
Still deployed on one service only; Phase 4 rolls this logic out everywhere.

### What was built

#### `sidecar/headers.go`
Header read/write helpers:

| Function | What it does |
|----------|-------------|
| `ReadTokenHeader(r)` | Parses `X-Rajomon-Tokens` as an integer; `ok=false` if missing or non-integer |
| `WriteTokenHeader(r, remaining)` | Sets `X-Rajomon-Tokens` on the outgoing proxied request to the remaining budget |
| `WritePriceHeader(w, price)` | Sets `X-Rajomon-Price` on the response, formatted to 2 decimal places |

#### `sidecar/pricing.go`
In-flight counter and price formula:

- `Metrics.IncInFlight()` / `DecInFlight()` — atomic increment/decrement, called at start/end of every proxied request
- `GetLocalPrice(cfg, metrics)` — returns `BasePrice + PriceScaleFactor × in_flight`

In-flight count is the congestion signal: a simple, real, well-established load signal (same
principle behind concurrency-based load-shedding libraries used in production systems).

#### `sidecar/admission.go`
Decision Table — implemented precisely as specified in phase_guide.txt §Phase 3:

| Tokens present & valid? | Tokens vs. price | Verdict | Upstream touched? |
|------------------------|-----------------|---------|------------------|
| No | — | `ForwardFailOpen` | Yes |
| Yes | tokens ≥ price | `Forward` | Yes |
| Yes | tokens < price | `RejectInsufficientTokens` | No |

#### `sidecar/admission_test.go`
Unit tests covering every row of the Decision Table (including edge cases), using Go's standard `testing` package.

#### `sidecar/config.go` (updated)
Added two new optional pricing fields with safe defaults:

| Env var | Default | Purpose |
|---------|---------|---------| 
| `RAJOMON_BASE_PRICE` | `1.0` | Minimum price even at zero load |
| `RAJOMON_PRICE_SCALE_FACTOR` | `0.5` | Price increase per in-flight request |

#### `sidecar/main.go` (updated)
The catch-all proxy handler now runs the full admission loop before forwarding:

```
metrics.IncInFlight()
defer metrics.DecInFlight()
tokens, ok = ReadTokenHeader(request)
price      = GetLocalPrice(config, metrics)
verdict    = Decide(tokens, ok, price)

RejectInsufficientTokens → 503 "rajomon-http: insufficient tokens for current price"
Forward                  → WriteTokenHeader(remaining), proxy, WritePriceHeader
ForwardFailOpen          → proxy unchanged, WritePriceHeader (no token accounting)
```

#### `docker-compose.yml` (updated)
Added `RAJOMON_BASE_PRICE` and `RAJOMON_PRICE_SCALE_FACTOR` to the `sidecar-compose-post` service.

### Exit conditions verified
- ✅ `go test ./sidecar/...` passes, covering all three Decision Table rows
- ✅ `curl -H "X-Rajomon-Tokens: 100" http://localhost:9464/...` → normal upstream response + `X-Rajomon-Price` header on response
- ✅ `curl -H "X-Rajomon-Tokens: 0" http://localhost:9464/...` → `503` with body `rajomon-http: insufficient tokens for current price`; no new log line in `compose-post-service` logs
- ✅ `curl http://localhost:9464/...` (no token header) → succeeds normally (fail-open)
- ✅ Commit: `[Phase 3] Admission Engine -- token/price decision logic live on compose-post-service`

---

## Phase 4 — Fleet Rollout & Metrics

**Goal:** Deploy the admission-engine sidecar in front of **all 11 business-logic services**
and expose real Prometheus metrics from every sidecar. Add a Prometheus scraper and a
pre-built Grafana dashboard so the fleet is fully observable before load testing begins.

### What was built

#### `sidecar/metrics.go` (new)
Defines `SidecarMetrics` — three Prometheus instruments registered at startup, all
`ConstLabelled` with `service_name` so a single dashboard query fans out across the fleet:

| Metric | Type | Labels | What it measures |
|--------|------|--------|-----------------|
| `rajomon_sidecar_requests_total` | Counter | `service_name`, `verdict` | Request count by admission verdict |
| `rajomon_sidecar_in_flight_requests` | Gauge | `service_name` | Live concurrency (the congestion signal) |
| `rajomon_sidecar_admission_price` | Histogram | `service_name`, `verdict` | Price distribution (p50/p95/p99 queryable) |

#### `sidecar/pricing.go` (updated)
`Metrics` struct gains a `pm *SidecarMetrics` field. `IncInFlight` / `DecInFlight` now mirror
every atomic counter change to the Prometheus gauge — one source of truth, two consumers.

#### `sidecar/main.go` (updated)
- `/metrics` now serves `promhttp.Handler()` instead of an empty placeholder.
- Each verdict branch records `RequestsTotal` and `AdmissionPrice` before returning.

#### `sidecar/Dockerfile` (updated)
Builder stage now runs `go mod tidy && go mod download` after copying source, so the
`prometheus/client_golang` dependency is automatically resolved in the Docker build cache
without requiring a local Go installation.

#### `docker-compose.yml` (updated — full fleet)
- **YAML anchor** `x-sidecar-defaults` DRY-ifies common sidecar config (build, restart, base env).
- **`restart: "no"`** — fixed from the invalid uppercase `restart: NO`.
- **Pricing env vars** now reference `.env` with defaults:
  `RAJOMON_BASE_PRICE: "${RAJOMON_BASE_PRICE:-1.0}"` — tune fleet-wide from one `.env` file.
- **10 new sidecar services** added (ports 9465–9474), one per remaining service.
- **`prometheus`** service: `prom/prometheus:v2.53.0`, config mounted from `./monitoring/prometheus/prometheus.yml`, exposed on `:9090`.
- **`grafana`** service: `grafana/grafana:11.1.0`, provisioning and dashboards auto-loaded, exposed on `:3000`, anonymous viewer access enabled for demos.

#### `monitoring/prometheus/prometheus.yml` (new)
Scrapes `/metrics` from all 11 sidecar containers every **5 seconds** by container name.
Self-monitors Prometheus too.

#### `monitoring/grafana/` (new)
Auto-provisioned datasource + dashboard provider + `rajomon_fleet.json` dashboard with 6 panels:

| Panel | Query |
|-------|-------|
| Total req/s (stat) | `sum(rate(rajomon_sidecar_requests_total[1m]))` |
| Rejection rate (stat) | `sum(rate(...{verdict="reject_..."}[1m])) / sum(rate(...[1m]))` |
| Total in-flight (stat) | `sum(rajomon_sidecar_in_flight_requests)` |
| Request rate by service & verdict (timeseries) | `rate(rajomon_sidecar_requests_total[1m])` |
| In-flight per sidecar (timeseries) | `rajomon_sidecar_in_flight_requests` |
| Price p50/p95/p99 per service (timeseries) | `histogram_quantile(0.{50,95,99}, ...)` |

### Exit conditions to verify
- [ ] `docker compose up -d --build` starts 38 containers with no failures (27 DSB + 11 sidecars + Prometheus + Grafana + Jaeger)
- [ ] `curl http://localhost:9464/metrics` → Prometheus text format with `rajomon_sidecar_*` metrics
- [ ] `curl http://localhost:9465/metrics` → metrics for `social-graph-service`
- [ ] Prometheus UI (`http://localhost:9090`) → Status > Targets — all 11 sidecar targets `UP`
- [ ] Grafana (`http://localhost:3000`) → "Rajomon-HTTP — Sidecar Fleet Overview" dashboard loads with live data
- [ ] Commit: `[Phase 4] Fleet Rollout & Metrics -- all 11 sidecars + Prometheus + Grafana`

---

## Quick Start (from a clean clone)

```bash
git clone https://github.com/siddheshpohare/Rajamon-HTTP-extended.git
cd Rajamon-HTTP-extended
cp .env.example .env          # adjust if needed

# Start everything (Phase 1–4: benchmark app + 11 sidecars + Prometheus + Grafana)
docker compose up -d --build

# Verify Phase 1 — Social Network entry point
curl http://localhost:8080/

# Verify sidecar health (repeat for ports 9465–9474)
curl http://localhost:9464/healthz

# View live Prometheus metrics from compose-post sidecar
curl http://localhost:9464/metrics

# Check all sidecar targets are UP in Prometheus
open http://localhost:9090/targets

# Open Grafana fleet dashboard (admin/rajomon or anonymous viewer)
open http://localhost:3000
```

---

## Environment Variables

All tunable parameters live in `.env` (local, gitignored). See `.env.example` for the full reference.

| Variable | Default | Purpose |
|----------|---------|---------| 
| `COMPOSE_PROJECT_NAME` | `rajomon-http` | Namespaces Docker container/network names |
| `SOCIAL_NETWORK_NGINX_PORT` | `8080` | Port the DSB nginx frontend is exposed on |
| `RAJOMON_SERVICE_NAME` | _(set per sidecar in compose)_ | Sidecar instance identifier |
| `RAJOMON_LISTEN_ADDR` | _(set per sidecar in compose)_ | Port the sidecar listens on |
| `RAJOMON_UPSTREAM_ADDR` | _(set per sidecar in compose)_ | Upstream service address |
| `RAJOMON_BASE_PRICE` | `1.0` | _(Phase 3+)_ Minimum admission price — applies to ALL sidecars |
| `RAJOMON_PRICE_SCALE_FACTOR` | `0.5` | _(Phase 3+)_ Price increase per in-flight request — applies to ALL sidecars |
| `GF_SECURITY_ADMIN_PASSWORD` | `rajomon` | _(Phase 4)_ Grafana admin password |

---

## Day-to-Day Commands

```bash
# Start the full stack
docker compose up -d --build

# Check all container statuses
docker compose ps

# View sidecar logs live (replace service name as needed)
docker compose logs -f sidecar-compose-post
docker compose logs -f sidecar-social-graph

# Run Go unit tests inside Docker (no local Go needed)
docker compose run --rm sidecar-compose-post go test ./...

# Scrape metrics from a specific sidecar
curl http://localhost:9464/metrics | grep rajomon

# Stop and clean up
docker compose down

# Nuclear reset (removes volumes too)
docker compose down -v && docker compose up -d --build
```

---

## Useful Ports

| Port | Service |
|------|---------|
| `8080` | Social Network HTTP entry point (`nginx-thrift`) |
| `8081` | Media frontend |
| `9464` | Sidecar — `compose-post-service` |
| `9465` | Sidecar — `social-graph-service` |
| `9466` | Sidecar — `post-storage-service` |
| `9467` | Sidecar — `user-timeline-service` |
| `9468` | Sidecar — `url-shorten-service` |
| `9469` | Sidecar — `user-service` |
| `9470` | Sidecar — `media-service` |
| `9471` | Sidecar — `text-service` |
| `9472` | Sidecar — `unique-id-service` |
| `9473` | Sidecar — `user-mention-service` |
| `9474` | Sidecar — `home-timeline-service` |
| `9090` | Prometheus |
| `3000` | Grafana |
| `16686` | Jaeger tracing UI |
