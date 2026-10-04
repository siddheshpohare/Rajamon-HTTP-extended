# Rajamon-HTTP — What We Built & How to Verify It

> **Plain English guide** — what each phase is, what files we created, and exactly how to check it's working.

---

## The Big Picture

We are building a **traffic cop** that sits in front of every microservice.

When a request comes in, the cop asks:
- *"Do you have enough tokens to pay for this service right now?"*
- If yes → let it through
- If no → block it with a 503 error

This protects services from being overwhelmed during traffic spikes.

```
Client → [Sidecar / Traffic Cop] → Upstream Service
              ↑
        reads token header
        computes price from load
        forward or reject
```

The benchmark app we're protecting is **DeathStarBench Social Network** — 11 microservices that mimic Twitter (compose post, user service, timeline, etc.)

---

## Phase 1 — Get the Benchmark App Running

### What it is
Just getting DeathStarBench's Social Network app running in Docker. Nothing custom yet — this is the baseline we will later protect.

### What we did
- Copied the Social Network app into `benchmark-app/`
- Created a root `docker-compose.yml` that pulls it in
- Created `.env` for config

### Files involved
| File | What it does |
|------|-------------|
| `benchmark-app/docker-compose.yml` | Original DSB compose — 27 containers (microservices, DBs, Redis, Jaeger) |
| `docker-compose.yml` | Root file — uses `include:` to pull in the benchmark app |
| `.env` | Sets project name and ports |
| `benchmark-app/SERVICES.md` | Table of all 11 service names and their ports |

### ✅ How to verify it's working

```bash
# 1. Start everything
docker compose up -d --build

# 2. Check all containers are Up (should show 27+ containers, all "Up")
docker compose ps

# 3. Hit the Social Network frontend
curl http://localhost:8080/
# Expected: HTML page (Social Network login page) — HTTP 200
```

**If you see the login page HTML → Phase 1 is working.**

---

## Phase 2 — Build the Sidecar (Traffic Cop Skeleton)

### What it is
A Go program that sits in front of ONE service (`compose-post-service`) and **transparently forwards** every request. No blocking logic yet — just proving the plumbing works.

```
Client → [Sidecar :9464] → compose-post-service:9090
```

### What we did
- Wrote the sidecar in Go (`sidecar/` folder)
- It starts an HTTP server on port 9464
- Every request gets reverse-proxied to the real service unchanged
- Added it to `docker-compose.yml`

### Files created
| File | What it does |
|------|-------------|
| `sidecar/main.go` | HTTP server with `/healthz`, `/metrics`, and catch-all proxy handler |
| `sidecar/config.go` | Reads 3 env vars: service name, listen port, upstream address |
| `sidecar/Dockerfile` | Builds a tiny Go binary (multi-stage: build in golang:1.25, run in distroless) |
| `docker-compose.yml` | Added `sidecar-compose-post` service |

### ✅ How to verify it's working

```bash
docker compose up -d --build

# Sidecar health check
curl http://localhost:9464/healthz
# Expected: 200 OK with body "ok"

# View sidecar logs — you'll see every request logged
docker compose logs -f sidecar-compose-post
```

**If `/healthz` returns "ok" → Phase 2 is working.**

---

## Phase 3 — Admission Engine (The Actual Logic)

### What it is
Now the sidecar actually **makes a decision** on every request:

| Situation | What happens |
|-----------|-------------|
| No `X-Rajomon-Tokens` header | Forward anyway (fail-open — don't block unknown callers) |
| Tokens ≥ current price | Forward, deduct price from tokens |
| Tokens < current price | **Block with 503** — upstream never touched |

**Price formula:** `BasePrice + PriceScaleFactor × in_flight_requests`

So when the service is busy (many in-flight requests), the price goes up and low-token requests get rejected. This is the load shedding mechanism.

### What we built
| File | What it does |
|------|-------------|
| `sidecar/headers.go` | Reads `X-Rajomon-Tokens` from request, writes `X-Rajomon-Price` to response |
| `sidecar/pricing.go` | Tracks in-flight count atomically, computes price |
| `sidecar/admission.go` | `Decide()` function — implements the 3-row decision table |
| `sidecar/admission_test.go` | Unit tests for every case in the decision table |
| `sidecar/config.go` | Added `RAJOMON_BASE_PRICE` and `RAJOMON_PRICE_SCALE_FACTOR` env vars |

### ✅ How to verify it's working

```bash
docker compose up -d --build

# TEST 1: Forward (tokens=100, price=1.0 at idle → 100 >= 1.0 → allowed)
curl -v -H "X-Rajomon-Tokens: 100" http://localhost:9464/healthz
# Expected: 200 OK
# Look for response header: X-Rajomon-Price: 1.00

# TEST 2: Reject (tokens=0, price=1.0 → 0 < 1.0 → blocked)
curl -v -H "X-Rajomon-Tokens: 0" http://localhost:9464/
# Expected: 503 Service Unavailable
# Body: "rajomon-http: insufficient tokens for current price"

# TEST 3: Fail-open (no token header → forward anyway)
curl -v http://localhost:9464/healthz
# Expected: 200 OK (forwarded without token accounting)

# TEST 4: Run unit tests (no local Go needed — runs inside Docker)
docker compose run --rm sidecar-compose-post go test ./...
# Expected: PASS — all 6 test cases
```

> **IMPORTANT:** Use `/` (catch-all path) for the reject test, NOT `/healthz`.
> `/healthz` is a health probe — it intentionally skips admission so Docker can always check container health.

**If TEST 2 gives 503 → the admission engine is working.**

---

## Phase 4 — Fleet Rollout + Prometheus + Grafana

### What it is
Phase 3 only protected ONE service. Phase 4:
1. Deploys sidecars in front of **all 11 services**
2. Adds **Prometheus** to scrape live metrics from every sidecar
3. Adds **Grafana** with a pre-built dashboard to visualize it all

```
[All 11 Sidecars] ←scrape every 5s— [Prometheus :9090] ←reads— [Grafana :3000]
```

### What we built

#### New sidecar file
| File | What it does |
|------|-------------|
| `sidecar/metrics.go` | 3 Prometheus metrics: request counter, in-flight gauge, price histogram |

#### Updated sidecar files
| File | What changed |
|------|-------------|
| `sidecar/main.go` | `/metrics` now serves real Prometheus data (not empty placeholder) |
| `sidecar/pricing.go` | In-flight counter now also updates Prometheus gauge |
| `sidecar/Dockerfile` | Upgraded Go 1.22 → 1.25 (required by prometheus library) |

#### New monitoring files
| File | What it does |
|------|-------------|
| `monitoring/prometheus/prometheus.yml` | Tells Prometheus to scrape all 11 sidecars every 5 seconds |
| `monitoring/grafana/provisioning/datasources/prometheus.yml` | Auto-connects Grafana to Prometheus |
| `monitoring/grafana/dashboards/rajomon_fleet.json` | Pre-built dashboard with 6 panels |

#### Updated docker-compose.yml
- Added 10 new sidecars (ports 9465–9474), one per remaining service
- Added `prometheus` service on port 9090
- Added `grafana` service on port 3000
- Fixed `restart: NO` → `restart: "no"` (Docker only accepts lowercase)

### ✅ How to verify it's working

#### Step 1 — Start everything
```bash
docker compose up -d --build
# First time: downloads golang:1.25 image (~800MB), takes 3-5 min
# After that: uses cached layers, takes ~30 seconds
```

#### Step 2 — Check all containers started
```bash
docker compose ps
# Should show 38 containers, all "Up"
# Key ones to look for:
#   rajomon-http-prometheus-1     Up   0.0.0.0:9090->9090/tcp
#   rajomon-http-grafana-1        Up   0.0.0.0:3000->3000/tcp
#   rajomon-http-sidecar-*-1      Up   (11 of these, ports 9464-9474)
```

#### Step 3 — Check a sidecar's metrics endpoint
```bash
curl http://localhost:9464/metrics
# Expected: wall of text in Prometheus format
# Look for these specific lines:
#   rajomon_sidecar_in_flight_requests{service_name="compose-post-service"} 0
#   # HELP rajomon_sidecar_requests_total ...
```

#### Step 4 — Check Prometheus is scraping all sidecars
Open **http://localhost:9090/targets** in your browser.

You should see:
- `prometheus` job → 1 target → 🟢 **UP**
- `rajomon_sidecars` job → 11 targets → all 🟢 **UP**

If any show 🔴 DOWN → wait 30 seconds and refresh.

#### Step 5 — Check Grafana
Open **http://localhost:3000**
- Login: `admin` / `rajomon`
- Go to **Dashboards → Rajomon-HTTP — Sidecar Fleet Overview**
- Panels show zeros if no traffic — that's correct (system is idle)

#### Step 6 — Send test traffic to see live data in Grafana
Run this in PowerShell:

```powershell
# Forward requests (tokens=100, will be allowed)
1..20 | ForEach-Object {
    Invoke-WebRequest -Uri "http://localhost:9464/healthz" `
        -Headers @{"X-Rajomon-Tokens"="100"} -UseBasicParsing | Out-Null
}

# Reject requests (tokens=0, will be blocked with 503)
1..20 | ForEach-Object {
    try {
        Invoke-WebRequest -Uri "http://localhost:9464/" `
            -Headers @{"X-Rajomon-Tokens"="0"} -UseBasicParsing -ErrorAction Stop | Out-Null
    } catch {}
}

# Fail-open requests (no header, passes through)
1..10 | ForEach-Object {
    Invoke-WebRequest -Uri "http://localhost:9464/healthz" -UseBasicParsing | Out-Null
}

Write-Host "Done! Refresh Grafana at http://localhost:3000"
```

Now refresh Grafana — the request rate and rejection panels should show activity.

---

## The 3 Prometheus Metrics We Track

| Metric name | Type | What it tracks |
|-------------|------|----------------|
| `rajomon_sidecar_requests_total` | Counter | Total requests, split by service and verdict (forward/reject/fail-open) |
| `rajomon_sidecar_in_flight_requests` | Gauge | How many requests are in-progress RIGHT NOW — this is the load signal |
| `rajomon_sidecar_admission_price` | Histogram | What price was charged — p50/p95/p99 queryable |

All labelled with `service_name` → one query covers all 11 sidecars.

---

## Useful Prometheus Queries

Paste these into **http://localhost:9090**:

```promql
# Requests per second (all sidecars)
rate(rajomon_sidecar_requests_total[1m])

# What fraction of requests are being rejected?
sum(rate(rajomon_sidecar_requests_total{verdict="reject_insufficient_tokens"}[1m]))
/
sum(rate(rajomon_sidecar_requests_total[1m]))

# Current in-flight per service
rajomon_sidecar_in_flight_requests

# 95th percentile admission price per service
histogram_quantile(0.95, rate(rajomon_sidecar_admission_price_bucket[1m]))
```

---

## All Ports at a Glance

| Port | What's there |
|------|-------------|
| **8080** | Social Network frontend (nginx) |
| **8081** | Media frontend |
| **9090** | Prometheus |
| **3000** | Grafana (admin / rajomon) |
| **16686** | Jaeger tracing UI |
| **9464** | Sidecar — `compose-post-service` |
| **9465** | Sidecar — `social-graph-service` |
| **9466** | Sidecar — `post-storage-service` |
| **9467** | Sidecar — `user-timeline-service` |
| **9468** | Sidecar — `url-shorten-service` |
| **9469** | Sidecar — `user-service` |
| **9470** | Sidecar — `media-service` |
| **9471** | Sidecar — `text-service` |
| **9472** | Sidecar — `unique-id-service` |
| **9473** | Sidecar — `user-mention-service` |
| **9474** | Sidecar — `home-timeline-service` |

---

## Day-to-Day Commands

```bash
# Start everything
docker compose up -d --build

# Stop everything (keeps images cached for fast restart)
docker compose down

# Nuclear reset — wipes volumes (fresh DB state)
docker compose down -v

# Watch a sidecar's logs live
docker compose logs -f sidecar-compose-post

# See all container statuses
docker compose ps

# Run Go unit tests (no local Go needed)
docker compose run --rm sidecar-compose-post go test ./...
```

---

## What's Left (Phases 6–7)

| Phase | What it is |
|-------|-----------|
| **5** | ✅ **DONE** — Envoy gateway at the front — two configs (permissive/hardened) to empirically test header survival |
| **6** | Run wrk2 load tests — measure latency/goodput with Rajomon vs without |
| **7** | Full end-to-end walkthrough and final writeup |

---

## Phase 5 — Gateway & Header-Survival Test

### What it is
An Envoy gateway sits in front of the whole system on port **10000**. The single biggest open risk in the project — does `X-Rajomon-Tokens` actually survive a real gateway hop? — is tested empirically with two deliberately different configs.

```
Client → [Envoy :10000] → sidecar-compose-post:9464 → compose-post-service:9090
```

### What we built
| File | What it does |
|------|-------------|
| `gateway-config/envoy-permissive.yaml` | Standard Envoy config, no header filtering — `X-Rajomon-Tokens` passes through intact |
| `gateway-config/envoy-hardened.yaml` | Envoy with `header_mutation` filter that explicitly removes `x-rajomon-tokens` — simulates a restrictive production gateway |
| `load-tests/header-survival-check.sh` | Bash test script — checks sidecar logs for `FORWARD` vs `FAIL-OPEN` |
| `load-tests/header-survival-check.ps1` | PowerShell version — same logic, native Windows |
| `evaluation-results.md` | Results file — Phase 5 table + Phase 6 placeholders |
| `docker-compose.yml` | Two new Envoy services gated behind Compose profiles: `permissive` and `hardened` |

### ✅ How to verify it's working

```bash
# 1. Start with permissive config
docker compose --profile permissive up -d --build

# 2. Confirm gateway is up
curl http://localhost:10000/healthz
# Expected: 200 OK (routed through Envoy → sidecar → upstream health check)

# 3. Run PASS case
bash load-tests/header-survival-check.sh permissive
# Expected: PASS — sidecar log shows FORWARD with tokens=100

# 4. Swap to hardened config
docker compose --profile permissive down
docker compose --profile hardened up -d

# 5. Run FAIL case
bash load-tests/header-survival-check.sh hardened
# Expected: FAIL (expected) — sidecar FAIL-OPEN, request still completes (no crash)

# PowerShell equivalent:
.\load-tests\header-survival-check.ps1 -Config permissive
.\load-tests\header-survival-check.ps1 -Config hardened
```

### The Core Risk (Why This Test Exists)

| Config | What happens to X-Rajomon-Tokens | System behaviour | Safe? |
|--------|----------------------------------|-----------------|-------|
| Permissive | Survives → admission runs normally | Tokens accounted, price enforced | ✅ Yes |
| Hardened | Stripped → sidecar FAIL-OPENs | Request passes without token accounting | ✅ Yes (safely degraded, not crashed) |

The mechanism breaks **silently** under a hardened gateway. This is intentional (fail-open > fail-closed for availability) but must be known and documented before Phase 6 evaluation.

---

## All Ports at a Glance

| Port | What's there |
|------|-------------|
| **8080** | Social Network frontend (nginx) |
| **8081** | Media frontend |
| **9090** | Prometheus |
| **3000** | Grafana (admin / rajomon) |
| **16686** | Jaeger tracing UI |
| **10000** | Envoy gateway — `--profile permissive` or `--profile hardened` |
| **9901** | Envoy admin UI |
| **9464** | Sidecar — `compose-post-service` |
| **9465** | Sidecar — `social-graph-service` |
| **9466** | Sidecar — `post-storage-service` |
| **9467** | Sidecar — `user-timeline-service` |
| **9468** | Sidecar — `url-shorten-service` |
| **9469** | Sidecar — `user-service` |
| **9470** | Sidecar — `media-service` |
| **9471** | Sidecar — `text-service` |
| **9472** | Sidecar — `unique-id-service` |
| **9473** | Sidecar — `user-mention-service` |
| **9474** | Sidecar — `home-timeline-service` |

---

## Day-to-Day Commands

```bash
# Start everything (base stack — no Envoy)
docker compose up -d --build

# Start with Envoy permissive gateway (Phase 5+)
docker compose --profile permissive up -d --build

# Start with Envoy hardened gateway (risk demonstration)
docker compose --profile hardened up -d --build

# Stop everything
docker compose down
docker compose --profile permissive down

# Nuclear reset — wipes volumes (fresh DB state)
docker compose down -v

# Watch a sidecar's logs live
docker compose logs -f sidecar-compose-post

# See all container statuses
docker compose ps

# Run Go unit tests (no local Go needed — runs inside Docker)
docker compose run --rm sidecar-compose-post go test ./...

# Run header-survival check
bash load-tests/header-survival-check.sh both         # bash / WSL
.\load-tests\header-survival-check.ps1 -Config both   # PowerShell
```
