# Rajomon-HTTP - Testing Guide

How to start the stack, run every test case, run a steady ~200 req/s load with 100 tokens, and show the Prometheus and Grafana graphs.

> Use **Git Bash** (Windows) or any bash shell. Docker Desktop must be running and **not paused**. Run all commands from the project root.

---

## 1. Prerequisites

| Need | Check |
|---|---|
| Docker Desktop running (not paused) | `docker info` |
| Docker Compose v2.20+ | `docker compose version` |
| curl | `curl --version` |
| ~6 GB free RAM, ports free: 3000, 8080, 8083, 9090, 9550-9554, 9901, 10000 | - |

```bash
cp .env.example .env        # only the first time
```

---

## 2. Start the stack

```bash
docker compose --profile permissive up -d --build
```

TeaStore needs **1-3 minutes** to warm up. Wait until all four internal services appear in the registry:

```bash
for s in webui auth image recommender persistence; do
  echo -n "$s: "; curl -s http://localhost:8083/tools.descartes.teastore.registry/rest/services/tools.descartes.teastore.$s/; echo
done
```

Expected (the four internal services are registered **as their sidecars**):

```
webui: ["teastore-webui-upstream:8080"]
auth: ["teastore-auth:9551"]
image: ["teastore-imageprovider:9552"]
recommender: ["teastore-recommender:9553"]
persistence: ["teastore-persistence:9554"]
```

---

## 3. Run everything with one command

```bash
./load-tests/run-all-tests.sh
```

Other forms:

```bash
./load-tests/run-all-tests.sh --up                     # start the stack first, then test
./load-tests/run-all-tests.sh --skip-load              # functional checks only (no load)
./load-tests/run-all-tests.sh --skip-unit              # skip the Go unit tests
RATE=100 DURATION=20s ./load-tests/run-all-tests.sh    # gentler load
RATE=200 DURATION=60s TOKENS=100 ./load-tests/run-all-tests.sh
```

Settings: `RATE` (default 200 req/s), `DURATION` (30s), `TOKENS` (100), `MIN_SUCCESS` (95 = percent of 2xx required), `HOST` (localhost).
Exit code is `0` if every check passed and `1` otherwise.

### What it checks

| Test | What | Pass condition |
|---|---|---|
| T1 | `go vet` + `go test -v` in a golang container | no FAIL lines |
| T2 | `/healthz` on ports 9550-9554 | all 200 |
| T3 | TeaStore registry | auth/image/recommender/persistence registered as their sidecars (`teastore-<name>:955x`) |
| T4 | Entry sidecar `:9550` | tokens=100 -> 200 + `X-Rajomon-Price`; tokens=0 -> 503; no header -> 401; `abc` -> 401; tokens=1 -> 503 (ceil); tokens=2 -> 200; via Envoy `:10000` -> 200 |
| T5 | Persistence sidecar `:9554` directly | no header -> 200 (default 20-token budget); tokens=1 -> 503; `abc` -> 401 |
| T6 | Browse 5 shop pages through `:9550` | all 200 and **every one of the 5 sidecar counters increases** |
| T7 | Prometheus | 5 sidecar targets UP |
| T8 | Steady load, ~200 req/s, tokens=100 (vegeta, constant rate, not a spike) | success ratio >= 95% |
| T9 | After load | `queued = 0`, `in_flight = 0` on all 5; internal sidecars saw the load |

> The load test needs the `peterevans/vegeta` image (pulled automatically). If it can't be pulled, the script falls back to a paced `curl` generator, which may not reach the full rate.
> TeaStore's Java services decide the real limit: if your laptop cannot sustain 200 req/s the success ratio drops. Lower it with `RATE=100`.

---

## 4. The same tests by hand

### 4.1 Unit tests

```bash
docker run --rm -v "$(pwd -W 2>/dev/null || pwd)/sidecar:/src" -w /src golang:1.26 sh -c "go test ./... -v"
```

(Git Bash on Windows: prefix with `MSYS_NO_PATHCONV=1`.) Expected: `PASS` and `ok rajomon-http/sidecar`.

### 4.2 Health

```bash
for p in 9550 9551 9552 9553 9554; do echo -n "$p: "; curl -s -o /dev/null -w '%{http_code}\n' localhost:$p/healthz; done
```

### 4.3 Entry sidecar verdicts

```bash
U=http://localhost:9550/tools.descartes.teastore.webui/
curl -si -H "X-Rajomon-Tokens: 100" $U | head -8                                  # 200 + X-Rajomon-Price: 1.50
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Rajomon-Tokens: 0" $U             # 503
curl -s -o /dev/null -w '%{http_code}\n' $U                                       # 401 (strict)
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Rajomon-Tokens: abc" $U           # 401
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Rajomon-Tokens: 1" $U            # 503  (ceil(1.5)=2)
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Rajomon-Tokens: 2" $U            # 200
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Rajomon-Tokens: 100" http://localhost:10000/tools.descartes.teastore.webui/   # 200 via Envoy
```

### 4.4 Internal sidecar (default budget)

```bash
Q=http://localhost:9554/tools.descartes.teastore.persistence/rest/categories
curl -s -o /dev/null -w '%{http_code}\n' $Q                                  # 200 (default 20 tokens)
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Rajomon-Tokens: 1" $Q        # 503
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Rajomon-Tokens: abc" $Q      # 401
```

### 4.5 Prove all five sidecars are in the path

```bash
for p in 9550 9551 9552 9553 9554; do echo -n "$p: "; curl -s localhost:$p/metrics | grep '^rajomon_sidecar_requests_total' | grep -v '^#' | tr '\n' ' '; echo; done
for u in "" "category?category=2&page=1" "product?id=7" "login" "cart"; do
  curl -s -o /dev/null -w "$u -> %{http_code}\n" -H "X-Rajomon-Tokens: 100" "http://localhost:9550/tools.descartes.teastore.webui/$u"
done
# run the metrics loop again - every sidecar's forward count must be higher
docker compose logs --tail=4 sidecar-persistence sidecar-auth      # FORWARD ... tokens=20->18 price=1.50
```

### 4.6 Steady load by hand: 200 req/s, tokens=100

```bash
echo "GET http://localhost:9550/tools.descartes.teastore.webui/" | \
  docker run --rm -i --network host peterevans/vegeta sh -c \
  "vegeta attack -rate=200 -duration=30s -timeout=15s -header 'X-Rajomon-Tokens: 100' | vegeta report"
```

Look at `Requests [total, rate, throughput]`, `Success [ratio]` and `Status Codes`. While it runs, open Grafana (section 7).

### 4.7 Optional: heavy spike that triggers shedding (separate from the steady test)

```bash
docker run --rm --network host williamyeh/wrk -t8 -c200 -d30s -H "X-Rajomon-Tokens: 50" http://localhost:9550/tools.descartes.teastore.webui/
```

With 50 tokens the price passes 50 at 99 concurrent requests, so ~99.9% get a 503 and the Grafana rejection panels jump. Skip this on a slow laptop: heavy spikes have hung Docker Desktop before.

### 4.8 Header survival through Envoy (optional)

```bash
./load-tests/header-survival-check.sh                            # permissive: FORWARD
docker compose --profile permissive down
docker compose --profile hardened up -d                          # Envoy strips the header
./load-tests/header-survival-check.sh                            # sidecar answers 401
docker compose --profile hardened down && docker compose --profile permissive up -d
```

---

## 5. Stop / reset

```bash
docker compose --profile permissive down              # stop
docker compose --profile permissive down -v           # stop and delete volumes
docker compose --profile permissive up -d --build     # rebuild after code changes
```

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `Docker Desktop is manually paused` | Unpause in the Docker Desktop window |
| `open //./pipe/dockerDesktopLinuxEngine` | Docker Desktop is not running - start it |
| Pages return 500/502 right after start | TeaStore still warming up - wait 1-3 min, re-check the registry (section 2) |
| Registry shows `-upstream:8080` for internal services | Stale containers: `docker compose --profile permissive down` then `up -d --build` |
| Load test success ratio low | Lower the rate: `RATE=100`; close other heavy apps |
| Docker hangs under heavy load | Don't run the 200-connection spike (4.7) on a weak machine |
| Port already in use | Stop the other process, or `docker compose down` first |

---

## 7. Show the Prometheus and Grafana graphs (do this last)

Start a load first so the graphs have data (section 3 or 4.6), and keep it running while you present.

### 7.1 Grafana (the main dashboard)

1. Open **http://localhost:3000**. Anonymous viewing is enabled; to edit sign in as `admin` / `rajomon`.
2. Open the dashboard directly: **http://localhost:3000/d/rajomon-fleet** (or Dashboards -> *Rajomon-HTTP - Sidecar Fleet Overview*).
3. Top right: set the time range to **Last 15 minutes** and refresh to **5s**.
4. Panels to point at:

| Panel | What it shows |
|---|---|
| Total Requests (all sidecars) | Total requests handled |
| Rejection Rate (all sidecars) | Share of requests rejected (near 0 in the steady test, near 1.0 in the 50-token spike) |
| Total In-Flight (all sidecars) | Requests currently in flight (rises with load, returns to 0) |
| Request Rate by Service & Verdict | Per-sidecar rate of `forward` / `reject_insufficient_tokens` / `reject_missing_tokens` - **all five services appear** |
| In-Flight Requests per Sidecar | Live in-flight count per sidecar |
| Admission Price p50 / p95 / p99 per Service | Price at decision time; rises with load |

5. To show the **internal sidecars** are used, point at the auth / imageprovider / recommender / persistence series in *Request Rate by Service & Verdict*.
6. For a screenshot: use the OS screenshot tool (e.g. `Win+Shift+S`) on a time window that includes the load, or Grafana's *Share* button.

### 7.2 Prometheus

Open **http://localhost:9090**.

* **Targets:** *Status -> Targets* (http://localhost:9090/targets): all 5 `rajomon_sidecars` targets must be **UP**.
* **Graph:** http://localhost:9090/graph, paste a query, click *Execute*, then the *Graph* tab.

```promql
# request rate per sidecar and verdict
sum by (service_name, verdict) (rate(rajomon_sidecar_requests_total[1m]))

# rejection fraction
sum(rate(rajomon_sidecar_requests_total{verdict="reject_insufficient_tokens"}[1m]))
  / sum(rate(rajomon_sidecar_requests_total[1m]))

# live in-flight / queued per sidecar
rajomon_sidecar_in_flight_requests
rajomon_sidecar_queued_requests

# 95th percentile admission price per service
histogram_quantile(0.95, sum by (le, service_name) (rate(rajomon_sidecar_admission_price_bucket[1m])))

# are all five sidecar targets up? (expect 5)
count(up{job="rajomon_sidecars"} == 1)
```

### 7.3 Raw metrics and logs (alternative evidence)

```bash
curl -s localhost:9550/metrics | grep rajomon_sidecar                    # raw metrics of the entry sidecar
docker compose logs -f sidecar-webui sidecar-persistence                 # live FORWARD / REJECT lines
```

### 7.4 Suggested demo order

1. `docker compose --profile permissive up -d` and show the registry output (section 2).
2. Open Grafana (`/d/rajomon-fleet`), time range *Last 15 minutes*, refresh *5s*.
3. Run `./load-tests/run-all-tests.sh` and watch the PASS lines and the panels move together.
4. Show Prometheus *Targets* (5 UP) and one or two PromQL queries.
5. Optional, strong machines only: the 50-token spike (4.7) to show the rejection rate and price panels jump.
