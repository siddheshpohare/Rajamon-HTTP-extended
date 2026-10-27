# TeaStore — Service Reference

All services in the TeaStore benchmark application, with their internal ports and sidecar assignments.

> This file is the Phase B equivalent of the old `SERVICES.md` for DeathStarBench.
> It is the authoritative reference used by sidecar configuration in the root `docker-compose.yml`.

---

## Business-Logic Services (Sidecar-Protected)

| Service | Internal Hostname (upstream) | Internal Port | Sidecar Port (host) | Sidecar Service Name |
|---------|------------------------------|---------------|--------------------|--------------------|
| Web UI | `teastore-webui-upstream` | 8080 | 9550 | `sidecar-webui` |
| Auth | `teastore-auth-upstream` | 8080 | 9551 | `sidecar-auth` |
| Image Provider | `teastore-imageprovider-upstream` | 8080 | 9552 | `sidecar-imageprovider` |
| Recommender | `teastore-recommender-upstream` | 8080 | 9553 | `sidecar-recommender` |
| Persistence | `teastore-persistence-upstream` | 8080 | 9554 | `sidecar-persistence` |

## Infrastructure Services (No Sidecar)

| Service | Hostname | Port | Reason — no sidecar |
|---------|----------|------|---------------------|
| Service Registry | `teastore-registry` | 8080 | Infrastructure plumbing — not a business-logic service |
| Database | `teastore-db` | 3306 | MySQL binary protocol — sidecar is HTTP-only |

---

## How the Network Alias Trick Works

Each real service container has its hostname set to `teastore-<name>-upstream`.  
Each sidecar container takes a Docker **network alias** of `teastore-<name>`.

When `teastore-webui` makes a REST call to `teastore-auth`, Docker DNS resolves  
`teastore-auth` → `sidecar-auth` (port 9551) → the sidecar runs admission control  
→ then forwards to `teastore-auth-upstream:8080`.

**Zero application code changes.** Zero Thrift. All REST.

---

## Communication Protocol

| Hop | Protocol | Header carried |
|-----|----------|----------------|
| Client → Envoy Gateway | HTTP/1.1 | `X-Rajomon-Tokens: <n>` |
| Envoy → sidecar-webui | HTTP/1.1 | `X-Rajomon-Tokens: <n>` (permissive) or stripped (hardened) |
| sidecar → teastore-webui-upstream | HTTP/1.1 | `X-Rajomon-Tokens: <n - price>` |
| teastore-webui → sidecar-auth (via alias) | HTTP/1.1 | `X-Rajomon-Tokens: <remaining>` |
| Any sidecar → response | HTTP/1.1 | `X-Rajomon-Price: <price>` on response |

---

## Port Quick-Reference

| Port | What |
|------|------|
| `8080` | teastore-webui direct (baseline / no-sidecar mode) |
| `8083` | teastore-registry HTTP API |
| `3306` | MariaDB |
| `9550` | sidecar-webui |
| `9551` | sidecar-auth |
| `9552` | sidecar-imageprovider |
| `9553` | sidecar-recommender |
| `9554` | sidecar-persistence |
| `10000` | Envoy Gateway |
| `9901` | Envoy Admin UI |
| `9090` | Prometheus |
| `3000` | Grafana |
