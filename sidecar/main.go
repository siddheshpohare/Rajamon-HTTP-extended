package main

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
)

func main() {
	cfg := LoadConfigFromEnv()

	// Parse the upstream address into a URL for the reverse proxy
	upstreamURL, err := url.Parse("http://" + cfg.UpstreamAddr)
	if err != nil {
		log.Fatalf("sidecar: invalid RAJOMON_UPSTREAM_ADDR %q: %v", cfg.UpstreamAddr, err)
	}

	proxy := httputil.NewSingleHostReverseProxy(upstreamURL)

	mux := http.NewServeMux()

	// GET /healthz — liveness probe
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// GET /metrics — Phase 2: placeholder (real Prometheus metrics arrive in Phase 4)
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		// Empty body — placeholder until Phase 4 wires up prometheus/client_golang
	})

	// Catch-all — reverse-proxy every other request to the upstream unchanged
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("sidecar[%s]: %s %s -> %s", cfg.ServiceName, r.Method, r.URL.Path, cfg.UpstreamAddr)
		proxy.ServeHTTP(w, r)
	})

	log.Printf("sidecar[%s]: listening on %s, upstream %s", cfg.ServiceName, cfg.ListenAddr, cfg.UpstreamAddr)
	if err := http.ListenAndServe(cfg.ListenAddr, mux); err != nil {
		log.Fatalf("sidecar: server error: %v", err)
	}
}
