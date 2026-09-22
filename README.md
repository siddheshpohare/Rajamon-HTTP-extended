# Rajomon-HTTP

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
Rajomon-HTTP/
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
│   ├── main.go                 # HTTP server: /healthz, /metrics, catch-all proxy handler
│   ├── config.go               # SidecarConfig struct + LoadConfigFromEnv()
│   ├── go.mod                  # Go module: rajomon-http/sidecar
│   └── Dockerfile              # Multi-stage build: golang:1.22 → distroless/static
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
| 3 | Admission Engine | 🔜 Next | Token/price decision logic on `compose-post-service` |
| 4 | Fleet Rollout & Metrics | ⏳ Later | Sidecars on all services + Prometheus |
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

### Exit conditions to verify
- [ ] `curl http://localhost:9464/healthz` → `200 OK`
- [ ] Same request sent directly to `compose-post-service` and through the sidecar returns identical response
- [ ] `docker compose logs sidecar-compose-post` shows a log line for every proxied request
- [ ] Commit: `[Phase 2] Sidecar Skeleton -- transparent pass-through proxy live in front of compose-post-service`

---

## Quick Start (from a clean clone)

```bash
git clone https://github.com/siddheshpohare/Rajamon-HTTP-extended.git
cd Rajomon-HTTP-extended
cp .env.example .env          # adjust if needed

# Start everything (Phase 1 + Phase 2 sidecar)
docker compose up -d --build

# Verify Phase 1 — Social Network entry point
curl http://localhost:8080/

# Verify Phase 2 — sidecar healthcheck
curl http://localhost:9464/healthz

# View sidecar logs
docker compose logs -f sidecar-compose-post
```

---

## Environment Variables

All tunable parameters live in `.env` (local, gitignored). See `.env.example` for the full reference.

| Variable | Default | Purpose |
|----------|---------|---------|
| `COMPOSE_PROJECT_NAME` | `rajomon-http` | Namespaces Docker container/network names |
| `SOCIAL_NETWORK_NGINX_PORT` | `8080` | Port the DSB nginx frontend is exposed on |
| `RAJOMON_SERVICE_NAME` | _(set per sidecar in compose)_ | Sidecar instance identifier |
| `RAJOMON_LISTEN_ADDR` | `:9464` | Port the sidecar listens on |
| `RAJOMON_UPSTREAM_ADDR` | `compose-post-service:9090` | Upstream service address |
| `RAJOMON_BASE_PRICE` | `1.0` | _(Phase 3)_ Minimum admission price |
| `RAJOMON_PRICE_SCALE_FACTOR` | `0.5` | _(Phase 3)_ Price increase per in-flight request |

---

## Day-to-Day Commands

```bash
# Start the full stack
docker compose up -d --build

# Check all container statuses
docker compose ps

# View sidecar logs live
docker compose logs -f sidecar-compose-post

# Run Go unit tests inside Docker (no local Go needed)
docker compose run --rm sidecar-compose-post go test ./...

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
| `9464` | Sidecar for `compose-post-service` (Phase 2+) |
| `16686` | Jaeger tracing UI |
| `9090` | _(Phase 4)_ Prometheus |
| `3000` | _(Phase 4)_ Grafana |
