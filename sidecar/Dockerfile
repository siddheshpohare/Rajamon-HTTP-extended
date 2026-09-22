# ─── Stage 1: Build ───────────────────────────────────────────────────────────
# Use the official Go 1.22 image to compile a fully static binary.
# CGO_ENABLED=0 + GOOS=linux ensures no dynamic libc dependency,
# so the binary runs in a minimal distroless image (Stage 2).
FROM golang:1.22 AS builder

WORKDIR /build

# Copy module files first so Docker layer-caches the dependency download
# separately from the source code (speeds up rebuilds when only .go files change).
COPY go.mod ./
RUN go mod download

# Copy source and build a static binary
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o sidecar .

# ─── Stage 2: Runtime ─────────────────────────────────────────────────────────
# distroless/static has no shell, no package manager — just enough to run
# a static Go binary. No Go toolchain is present in this image (Phase Guide §2.3).
FROM gcr.io/distroless/static:nonroot

WORKDIR /app
COPY --from=builder /build/sidecar .

# The listen address is configured via RAJOMON_LISTEN_ADDR env var at runtime.
ENTRYPOINT ["/app/sidecar"]
