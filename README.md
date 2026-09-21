# Rajomon-HTTP

**A REST/HTTP extension of the Rajomon decentralised overload-control mechanism.**

Rajomon-HTTP extends the market-based token/price admission-control mechanism from
[Rajomon (NSDI '25)](https://www.usenix.org/conference/nsdi25) — originally built for gRPC — to
REST/HTTP microservice systems. It deploys as a transparent sidecar in front of each service,
requiring **zero application code changes**.

> See the [Phase Guide (PDF)](./RajomonHTTP_Phase_Guide.pdf) for step-by-step setup instructions.
> See the [Context Document (PDF)](./RajomonHTTP_Context_Document%20(1).pdf) for full design rationale.

---

## Authors

- Suraj Raj (2026MCS2801)
- Siddhesh Pohare (2026MCS2257)

*COL724 / COL7524 — Advanced Computer Networks, IIT Delhi — August 2026*

---

## Quick Start

```bash
cp .env.example .env
# Edit .env if any local values differ from defaults
docker compose up -d
docker compose ps
```

For full setup instructions (first-time clone, benchmark app initialisation, etc.) see the
**Phase Guide** PDF in the repository root.
