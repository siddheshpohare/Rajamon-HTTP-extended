# DeathStarBench — Social Network Services Reference

Source: `https://github.com/delimitrou/DeathStarBench`  
Commit inspected: `master` branch, `socialNetwork/docker-compose.yml`

> **Purpose:** Every later phase's sidecar config is built against this table.
> Do not edit by hand — re-generate by inspecting the actual compose file.

## Application Services (gRPC / Thrift — internal port 9090)

| Service Name | Internal Port | Entrypoint | Notes |
|---|---|---|---|
| `social-graph-service` | 9090 | `SocialGraphService` | Exposed as 10000:9090 (commented out in compose) |
| `compose-post-service` | 9090 | `ComposePostService` | **Primary evaluation target** — Phase 2+ sidecar starts here |
| `post-storage-service` | 9090 | `PostStorageService` | Exposed as 10002:9090 (active in compose) |
| `user-timeline-service` | 9090 | `UserTimelineService` | Exposed as 10003:9090 (commented out) |
| `url-shorten-service` | 9090 | `UrlShortenService` | Exposed as 10004:9090 (commented out) |
| `user-service` | 9090 | `UserService` | Exposed as 10005:9090 (commented out) |
| `media-service` | 9090 | `MediaService` | Exposed as 10006:9090 (commented out) |
| `text-service` | 9090 | `TextService` | Exposed as 10007:9090 (commented out) |
| `unique-id-service` | 9090 | `UniqueIdService` | Exposed as 10008:9090 (commented out) |
| `user-mention-service` | 9090 | `UserMentionService` | Exposed as 10009:9090 (commented out) |
| `home-timeline-service` | 9090 | `HomeTimelineService` | Exposed as 10010:9090 (commented out) |

## Frontend / Entry-Point Services (HTTP)

| Service Name | Internal Port | Host Port | Notes |
|---|---|---|---|
| `nginx-thrift` | 8080 | **8080** | Main HTTP entry point — used for Phase 1 baseline `curl` test |
| `media-frontend` | 8080 | **8081** | Media upload/download endpoint |

## Infrastructure / Data Services

| Service Name | Image | Purpose |
|---|---|---|
| `social-graph-mongodb` | `mongo:4.4.6` | Persistent store for social-graph-service |
| `social-graph-redis` | `redis` | Cache for social-graph-service |
| `home-timeline-redis` | `redis` | Cache for home-timeline-service |
| `post-storage-memcached` | `memcached` | Cache for post-storage-service |
| `post-storage-mongodb` | `mongo:4.4.6` | Persistent store for post-storage-service |
| `user-timeline-redis` | `redis` | Cache for user-timeline-service |
| `user-timeline-mongodb` | `mongo:4.4.6` | Persistent store for user-timeline-service |
| `url-shorten-memcached` | `memcached` | Cache for url-shorten-service |
| `url-shorten-mongodb` | `mongo:4.4.6` | Persistent store for url-shorten-service |
| `user-memcached` | `memcached` | Cache for user-service |
| `user-mongodb` | `mongo:4.4.6` | Persistent store for user-service |
| `media-memcached` | `memcached` | Cache for media-service |
| `media-mongodb` | `mongo:4.4.6` | Persistent store for media-service |

## Observability (Included in Benchmark App)

| Service Name | Image | Host Port | Purpose |
|---|---|---|---|
| `jaeger-agent` | `jaegertracing/all-in-one:latest` | 16686 | Distributed tracing UI |

---

## Phase 2+ Sidecar Port Allocation

Each Phase 2+ sidecar listens on a unique host port. Reserved range: **9464–9480**.

| Service | Sidecar Listen Port (`RAJOMON_LISTEN_ADDR`) | Upstream (`RAJOMON_UPSTREAM_ADDR`) |
|---|---|---|
| `compose-post-service` | `:9464` | `compose-post-service:9090` |
| `social-graph-service` | `:9465` | `social-graph-service:9090` |
| `post-storage-service` | `:9466` | `post-storage-service:9090` |
| `user-timeline-service` | `:9467` | `user-timeline-service:9090` |
| `url-shorten-service` | `:9468` | `url-shorten-service:9090` |
| `user-service` | `:9469` | `user-service:9090` |
| `media-service` | `:9470` | `media-service:9090` |
| `text-service` | `:9471` | `text-service:9090` |
| `unique-id-service` | `:9472` | `unique-id-service:9090` |
| `user-mention-service` | `:9473` | `user-mention-service:9090` |
| `home-timeline-service` | `:9474` | `home-timeline-service:9090` |
