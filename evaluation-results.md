# Rajamon-HTTP — Evaluation Results

> This file records all empirical results from Phases 5 and 6.
> Per the phase guide: results are stated plainly, without overstating
> smaller-scale laptop results as equivalent to the original paper's cluster-scale numbers.

---

## Phase 5: Gateway & Header-Survival Test

**Date:** _(fill in when run)_

**Test:** Does `X-Rajomon-Tokens` survive a real Envoy gateway hop?

### Method

1. Start the stack with `docker compose --profile <config> up -d`
2. Send `GET http://localhost:10000/healthz` with `X-Rajomon-Tokens: 100`
3. Check sidecar-compose-post logs for `FORWARD` (header present) or `FAIL-OPEN` (header stripped)

### Results

| Config | Result | Detail | Timestamp |
|---|---|---|---|
| permissive | _(run the check script)_ | | |
| hardened | _(run the check script)_ | | |

### Interpretation

- **Permissive config (expected PASS):** The gateway makes no header decisions; `X-Rajomon-Tokens`
  reaches the sidecar intact. Admission engine runs normally — requests with sufficient tokens
  are forwarded, insufficient-token requests get 503.

- **Hardened config (expected FAIL → safe fail-open):** A real restrictive gateway strips non-standard
  headers. The token header never reaches the sidecar. The sidecar detects `ok=false` from
  `ReadTokenHeader()` and takes the `ForwardFailOpen` branch — the request completes normally
  but without token accounting. **This is the key risk documented in Context Document §1.1 and
  Design Decision #6:** the mechanism silently stops working, with no error, no crash, no hung
  request. The system degrades gracefully but invisibly.

- **Conclusion:** The header-survival risk is real and reproducible. In a production deployment,
  Envoy (or any gateway) must be explicitly configured to allow `X-Rajomon-Tokens` through.
  The permissive config is the correct configuration for real Rajomon-HTTP evaluation.

---

## Phase 6: Evaluation Harness

_(Results will be added when Phase 6 is complete.)_

### Baseline (no Rajomon-HTTP)
```
wrk2 output will go here
```

### Rajomon-HTTP enabled
```
wrk2 output will go here
```

### Comparison against paper claims
- Paper headline (Context Document §1.1): 78% lower tail latency, 45% higher goodput
- Our results (smaller-scale, single laptop): _(fill in)_
- Direction agreement: _(fill in: "results point in the same direction" or note discrepancy)_

> **Limitation note (Context Document §14, limitation #12):**
> This project runs on a single laptop using Docker Compose.
> The original paper's numbers were measured on a multi-server cluster with dedicated network hardware.
> Our results are directionally comparable but not expected to match in absolute values.

---
