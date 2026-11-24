# Rajomon-HTTP - Source Code

**COL724 / COL7524 Advanced Computer Networks**
Suraj Raj (2026MCS2801) - Siddhesh Pohare (2026MCS2257)

Rajomon-HTTP brings Rajomon-style token-and-price admission control (originally gRPC-only) to REST/HTTP microservices. A small Go **sidecar** reverse proxy sits in front of each service, reads the `X-Rajomon-Tokens` header, computes a congestion price, and either forwards the request or sheds it - with **no change to the protected application**. The benchmark app is **TeaStore** (5 REST/HTTP Spring Boot microservices).

> **How all five sidecars are used.** TeaStore services register `HOST_NAME` / `SERVICE_PORT` in the TeaStore registry and peers call whatever is registered. `benchmark-app/docker-compose.yml` registers Auth, ImageProvider, Recommender and Persistence **as their sidecars** (`teastore-<name>:9551-9554`); the real containers are `teastore-<name>-upstream`. So internal calls pass through all five sidecars - configuration only, no TeaStore code changed. TeaStore does not forward `X-Rajomon-Tokens`, so the four **internal** sidecars apply `RAJOMON_INTERNAL_DEFAULT_TOKENS` (20) to header-less calls; the **entry** sidecar (`sidecar-webui`, :9550) stays strict (no header -> 401). A malformed header is always 401. Budgets are therefore per service, not one end-to-end shrinking budget (future work: e.g. OpenTelemetry baggage). Ports 9551-9554 should only be reachable from a trusted network. The WebUI is also published on host `:8080` for baseline runs.

```
price = base_price + scale_factor x (queued + in_flight)      cost = ceil(price)
```

| Tokens header | tokens vs ceil(price) | Verdict | HTTP | Upstream touched |
|---|---|---|---|---|
| missing / invalid | - | RejectMissingTokens | 401 | No |
| present | tokens >= cost | Forward (tokens -= cost) | 200 | Yes |
| present | tokens < cost | RejectInsufficientTokens | 503 | No |

## Contents

```
3_Source_Code/
  sidecar/                  Go sidecar (the contribution)
    main.go                 /healthz, /metrics, admission + reverse proxy
    admission.go            Decide(), AdmissionCost() (math.Ceil)
    pricing.go              atomic Queued/InFlight counters, GetLocalPrice()
    headers.go              Read/Write token + price headers
    metrics.go              Prometheus counter, gauges, price histogram
    config.go               RAJOMON_* environment configuration
    admission_test.go       20 unit test cases (18 sub-tests + 2 standalone)
    Dockerfile, go.mod, go.sum
  benchmark-app/            TeaStore compose stack (included by root compose)
  gateway-config/           Envoy configs: permissive (passes header) / hardened (strips it)
  monitoring/               Prometheus scrape config + Grafana provisioning and fleet dashboard
  load-tests/               wrk Lua scripts and PowerShell/bash test scripts
  docker-compose.yml        Full stack: TeaStore + 5 sidecars + Envoy + Prometheus + Grafana
  .env.example              Tunable parameters
```

## Requirements

- Docker Desktop (Docker Compose v2.20+ for the `include:` directive)
- About 6 GB free RAM (TeaStore JVMs are heavy); ~60 s warm-up after start
- No local Go install needed - tests run in a container

## Run

```bash
cp .env.example .env
docker compose --profile permissive up -d      # or: --profile hardened
# wait ~60 s for TeaStore, then:
curl http://localhost:9550/healthz             # ok  (ports 9550-9554 = 5 sidecars)

# FORWARD  -> 200 + X-Rajomon-Price: 1.50
curl -si -H "X-Rajomon-Tokens: 100" http://localhost:9550/tools.descartes.teastore.webui/
# REJECT insufficient -> 503
curl -si -H "X-Rajomon-Tokens: 0"   http://localhost:9550/tools.descartes.teastore.webui/
# REJECT missing token -> 401
curl -si http://localhost:9550/tools.descartes.teastore.webui/
# tokens=1 < ceil(1.5)=2 -> 503
curl -si -H "X-Rajomon-Tokens: 1"   http://localhost:9550/tools.descartes.teastore.webui/
# Through the Envoy gateway (header survival, permissive profile) -> 200
curl -si -H "X-Rajomon-Tokens: 100" http://localhost:10000/tools.descartes.teastore.webui/

docker compose --profile permissive down       # stop (add -v to reset volumes)
```

To see that every sidecar is in the path: browse a page through `:9550`, then compare `curl localhost:9554/metrics` before and after - the counters increase. **`./load-tests/run-all-tests.sh` runs every check plus a steady 200 req/s load; see `TESTING_GUIDE.md` (also explains the Prometheus/Grafana graphs).**

### Unit tests (20 test cases)

```bash
docker run --rm -v "${PWD}/sidecar:/src" -w /src golang:1.26 sh -c "go test ./... -v"
```

### Load tests

```bash
# Spike: 200 connections, tokens=50, 30 s (price exceeds budget -> ~99.9% 503)
docker run --rm --network host williamyeh/wrk -t8 -c200 -d30s \
  -H "X-Rajomon-Tokens: 50" http://localhost:9550/tools.descartes.teastore.webui/

# Full scenario suite (PowerShell)
./load-tests/phase6-load-test.ps1
```

## Configuration (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `RAJOMON_BASE_PRICE` | 1.0 | Minimum price at zero load |
| `RAJOMON_PRICE_SCALE_FACTOR` | 0.5 | Price increase per active request |
| `RAJOMON_INTERNAL_DEFAULT_TOKENS` | 20 (internal sidecars) | Budget for header-less internal calls; unset/0 = strict 401 (entry sidecar) |
| `GF_SECURITY_ADMIN_USER` / `_PASSWORD` | admin / rajomon | Grafana login |
| `ENVOY_GATEWAY_PORT`, `ENVOY_ADMIN_PORT` | 10000, 9901 | Envoy ports |

## Ports

8080 TeaStore WebUI (also exposed directly, for baseline runs) - 9550-9554 sidecars (webui, auth, imageprovider, recommender, persistence) - 10000 Envoy - 9901 Envoy admin - 9090 Prometheus - 3000 Grafana (admin / rajomon)

## Prometheus metrics

`rajomon_sidecar_requests_total{verdict}`, `rajomon_sidecar_queued_requests`, `rajomon_sidecar_in_flight_requests`, `rajomon_sidecar_admission_price` (histogram). Example: `rate(rajomon_sidecar_requests_total[1m])`.

## Results summary (single-laptop Docker run, Nov 2026)

| Check | Result |
|---|---|
| Sidecar health (5/5), five-verdict curl checks, unit tests | All pass (20/20 test cases); re-verified 24 Nov 2026 |
| Price vs load (tokens=50) | First rejection at N=99 concurrent (price 50.50, cost 51) |
| Spike: 200 conn, tokens=50, 30 s (20 Nov) | wrk completed 514,442 requests at 17,117 req/s (96 timeouts). Sidecar counters: 514,536 rejected + 101 forwarded = 514,637 seen, i.e. 99.98% rejected. The sidecar total is higher than wrk's because it also counts requests at the window edges and ones wrk timed out |
| Spike re-run (24 Nov) | wrk 397,711 requests at 13,159 req/s; sidecar 342 forwarded, 397,524 rejected (99.91%); queued and in-flight return to 0 |
| Internal sidecars (24 Nov) | Functional smoke test only: all 5 counters rise while browsing; direct calls to :9554: no header 200, tokens=1 503, `abc` 401. **Not load-tested.** |
| Forward, 20 conn, tokens=100 | 468 req/s, 77 ms avg (19 Nov); a 24 Nov re-run on a busier host gave 92-112 req/s |
| Forward spike, 100 conn, tokens=100 | 292 req/s, 221 ms avg (19 Nov) |
| Rejection fast path (tokens=1), 100 conn | 68,302 req/s, 2.93 ms avg, upstream untouched |
| Missing-token path (401), 20 conn | 40,390 req/s, 1.17 ms avg, upstream untouched |
| Envoy header survival | Permissive: PASS (re-verified 24 Nov). Hardened: header stripped, sidecar rejects with 401 (the original 14 Oct test predates the strict-401 and ceil() changes, so it logged fail-open and `tokens=100->99`; the final rule gives `100->98`) |

These are laptop-scale results, directionally consistent with the design but not comparable in absolute terms to the original paper's cluster measurements.

## Design notes

- **Zero app changes:** the TeaStore code and images are untouched; only registry settings (`HOST_NAME`, `SERVICE_PORT`) and container names changed.
- **Three policy decisions:** strict 401 on missing token (no fail-open), combined `queued + in_flight` congestion signal, `ceil(price)` charge.
- **Price header:** injected via `ReverseProxy.ModifyResponse` plus a request-context value (setting it after `ServeHTTP` is silently lost).
- **History:** the project first targeted DeathStarBench Social Network, which speaks Apache Thrift (not HTTP) between services, so it was replaced by TeaStore.
