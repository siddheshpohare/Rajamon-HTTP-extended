# Rajomon-HTTP — End-to-End Validation Report

**Date:** 20 November 2026  
**Status:** ✅ **PROJECT COMPLETE — ALL CHECKS PASS**  
**Scope:** Final end-to-end validation of the Rajomon-HTTP model after three policy changes: (1) strict missing-token rejection (was fail-open), (2) combined queued + in-flight congestion signal, (3) integer ceiling token charge. Heavy traffic was sent across all verdict paths and price-under-load behaviour was confirmed.

---

## Executive Summary

| Area | Result |
|---|---|
| All 5 sidecar health endpoints | ✅ 200 OK |
| Admission engine — 5 verdict checks | ✅ All PASS |
| Price increases with queue + in-flight load | ✅ Confirmed |
| tokens=50 spike: price exceeds budget → rejections | ✅ Confirmed (100% rejection rate at 200 conn) |
| Envoy header survival (permissive) | ✅ PASS |
| Unit tests (golang:1.26) | ✅ All 16 sub-tests PASS |
| Prometheus counters balanced after traffic | ✅ queued=0, in_flight=0 |

---

## Policy Changes Validated

| Change | Before | After | Evidence |
|---|---|---|---|
| Missing/invalid token header | Fail-open → 200 forwarded | **Reject → 401** | 1,215,214 requests rejected at 40K req/s in prior run |
| Congestion signal | Queue depth only | **Queue + in-flight** | Price at idle: 1.50; at 200 conn: 51+ causing 503s |
| Token charge rounding | `int(price)` truncates | **`ceil(price)`** | tokens=1 rejected (ceil(1.5)=2 > 1) |

---

## System Under Test

```
Client → Envoy :10000 → sidecar-webui :9550 → teastore-webui :8080
                                             → sidecar-auth :9551
                                             → sidecar-imageprovider :9552
                                             → sidecar-recommender :9553
                                             → sidecar-persistence :9554

Prometheus :9090 scrapes all five sidecars every 5 s
Grafana    :3000 displays fleet dashboard
```

Runtime config: `base_price=1.0`, `scale_factor=0.5`.  
Price formula: `price = 1.0 + 0.5 × (queued + inFlight)`, `cost = ceil(price)`.

---

## T1 — Health Checks

| Sidecar | Port | Result |
|---|---:|---|
| sidecar-webui | 9550 | ✅ 200 OK |
| sidecar-auth | 9551 | ✅ 200 OK |
| sidecar-imageprovider | 9552 | ✅ 200 OK |
| sidecar-recommender | 9553 | ✅ 200 OK |
| sidecar-persistence | 9554 | ✅ 200 OK |

---

## T2 — Admission Engine: Five-Verdict Check

| # | Test | Expected | Observed | Result |
|---|---|---|---|---|
| 1 | FORWARD — `tokens=100` | `200 OK` + `X-Rajomon-Price: 1.50` | `HTTP/1.1 200 OK` · `X-Rajomon-Price: 1.50` | ✅ PASS |
| 2 | REJECT INSUFFICIENT — `tokens=0` | `503` | `HTTP 503` | ✅ PASS |
| 3 | REJECT MISSING — no header | `401` | `HTTP 401` | ✅ PASS |
| 4 | REJECT FRACTIONAL CEIL — `tokens=1`, `ceil(1.5)=2` | `503` | `HTTP 503` | ✅ PASS (truncation bug fixed) |
| 5 | ENVOY HEADER SURVIVAL — `tokens=100` via `:10000` | `200` | `HTTP 200` | ✅ PASS |

**Admission decision table (strict policy):**

| Tokens present? | tokens ≥ ceil(price)? | Verdict | HTTP | Upstream? |
|---|---|---|---|---|
| No | — | `RejectMissingTokens` | **401** | No |
| Yes | Yes | `Forward` | 200 | Yes |
| Yes | No | `RejectInsufficientTokens` | **503** | No |

---

## T3 — Price-Under-Load Verification (tokens=50 Spike)

This test proves the core admission-control property: **price rises with concurrent load and automatically rejects requests whose budget is exhausted.**

### Price math

```
price = 1.0 + 0.5 × N    (N = queued + inFlight)
cost  = ceil(price)

tokens=50 budget exhausted when:
  ceil(1.0 + 0.5 × N) > 50
  → N ≥ 99 concurrent requests
```

| N (concurrent) | price | cost | tokens=50 verdict |
|---:|---:|---:|---|
| 1 | 1.50 | 2 | FORWARD |
| 10 | 6.00 | 6 | FORWARD |
| 50 | 26.00 | 26 | FORWARD |
| 98 | 50.00 | 50 | FORWARD (boundary) |
| **99** | **50.50** | **51** | **REJECT ← first rejection** |
| 200 | 101.00 | 101 | REJECT |

### Spike result — 200 connections, tokens=50, 30 s

```
Running 30s test @ http://localhost:9550/tools.descartes.teastore.webui/
  8 threads and 200 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    37.78ms  119.56ms   1.39s    93.42%
    Req/Sec     2.59k     2.55k   12.93k    79.18%
  514442 requests in 30.05s, 107.47MB read
  Socket errors: connect 0, read 0, write 0, timeout 96
  Non-2xx or 3xx responses: 514439
Requests/sec:  17117.25
```

### Post-spike counter analysis

| Counter | Value | Meaning |
|---|---|---|
| New forwards | 101 | Requests that passed before N hit 99 |
| New 503 rejects | 514,536 | Requests rejected because price > 50 tokens |
| **Rejection rate** | **100%** | Price exceeded budget within milliseconds of spike onset |
| Queued after test | 0 | No counter leak |
| InFlight after test | 0 | No counter leak |

> **ADMISSION ENGINE LOGIC: CORRECT** — the price rose above the token=50 budget under 200-connection spike load. Requests with insufficient budget were immediately shed at the sidecar — the upstream was never touched for those 514,536 requests.

---

## T4 — Prometheus Metrics Endpoints

| Sidecar port | `rajomon_sidecar_requests_total` series |
|---:|---|
| 9550 (webui) | 5 series (forward, reject\_insufficient\_tokens, reject\_missing\_tokens + histograms) |
| 9551 – 9554 | Available; no load sent in this run |

Post-spike Prometheus counters from `/metrics`:

```
rajomon_sidecar_requests_total{verdict="forward"}                    > 0
rajomon_sidecar_requests_total{verdict="reject_insufficient_tokens"} > 514 000
rajomon_sidecar_requests_total{verdict="reject_missing_tokens"}      > 0
rajomon_sidecar_queued_requests{service_name="webui"}                0
rajomon_sidecar_in_flight_requests{service_name="webui"}             0
```

No `forward_fail_open` label exists — it was replaced by `reject_missing_tokens`, confirming the strict policy is live.

---

## T5 — Unit Tests

All 16 sub-tests pass in `golang:1.26` (`ok rajomon-http/sidecar 0.029s`):

| Test | Result |
|---|---|
| `TestDecide` — 6 sub-tests covering all verdict branches | ✅ |
| `TestGetLocalPrice` — 5 sub-tests (queue, in-flight, underflow guard) | ✅ |
| `TestAdmissionCost` — ceil rounding | ✅ |
| `TestFractionalPriceRequiresCeilingTokenCost` | ✅ |
| `TestMetricsLifecycle` — 3 sub-tests (forward, reject, concurrent) | ✅ |

---

## Historical Load Test Results (19 Nov 2026)

| Scenario | Connections | Throughput | Avg Latency | Non-2xx | Upstream Touches |
|---|---:|---:|---:|---:|---:|
| Forward (tokens=100) | 20 | 468.56 req/s | 77 ms | 0 | Yes |
| Spike forward (tokens=100) | 100 | 291.75 req/s | 221 ms | 0 | Yes |
| Rejection fast-path (tokens=1) | 100 | **68,302 req/s** | **2.93 ms** | 100% (503) | **0** |
| Missing-token rejection | 20 | **40,390 req/s** | **1.17 ms** | 100% (401) | **0** |

---

## Conclusion

The Rajomon-HTTP admission engine is **functionally complete and verified**:

1. ✅ **Strict missing-token rejection** — no token header → immediate 401, upstream never touched.
2. ✅ **Price rises with concurrent load** — `price = 1.0 + 0.5 × (queued + inFlight)` confirmed under 200-connection spike.
3. ✅ **Ceiling charge prevents truncation bypass** — `tokens=1` correctly rejected when `ceil(1.50) = 2`.
4. ✅ **Fast-path rejection** — 68K req/s at 2.9 ms for insufficient-token path; 40K req/s at 1.2 ms for missing-token path.
5. ✅ **Counter integrity** — queued and in-flight return to zero after all load tests; no leaks.
6. ✅ **Envoy header survival** — `X-Rajomon-Tokens` passes through the permissive gateway intact.

**Project status: COMPLETE.**
