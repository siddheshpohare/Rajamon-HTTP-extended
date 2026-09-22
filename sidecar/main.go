package main

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
)

func main() {
	cfg := LoadConfigFromEnv()

	// Shared in-flight counter — updated atomically on every proxied request.
	metrics := &Metrics{}

	// Parse the upstream address into a URL for the reverse proxy.
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

	// GET /metrics — Phase 2 placeholder (real Prometheus metrics arrive in Phase 4)
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		// Empty body — placeholder until Phase 4 wires up prometheus/client_golang
	})

	// Catch-all — admission engine + reverse proxy (Phase 3)
	//
	// Pseudocode per phase_guide.txt §Phase 3:
	//   metrics.IncInFlight()
	//   defer metrics.DecInFlight()
	//   tokens, ok  = ReadTokenHeader(request)
	//   price       = GetLocalPrice(config, metrics)
	//   verdict     = Decide(tokens, ok, price)
	//   if verdict == RejectInsufficientTokens → 503, return
	//   if verdict == Forward                  → WriteTokenHeader, proxy, WritePriceHeader
	//   if verdict == ForwardFailOpen          → proxy, WritePriceHeader (no token accounting)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		metrics.IncInFlight()
		defer metrics.DecInFlight()

		tokens, tokensOK := ReadTokenHeader(r)
		price := GetLocalPrice(cfg, metrics)
		verdict := Decide(tokens, tokensOK, price)

		switch verdict {

		case RejectInsufficientTokens:
			// Upstream is never touched — respond immediately with 503.
			log.Printf("sidecar[%s]: REJECT %s %s tokens=%d price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, tokens, price)
			http.Error(w, "rajomon-http: insufficient tokens for current price",
				http.StatusServiceUnavailable)

		case Forward:
			// Deduct price from tokens, proxy, then stamp price onto the response.
			WriteTokenHeader(r, tokens-int(price))
			log.Printf("sidecar[%s]: FORWARD %s %s tokens=%d→%d price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, tokens, tokens-int(price), price)
			proxy.ServeHTTP(w, r)
			WritePriceHeader(w, price)

		case ForwardFailOpen:
			// No token header — proxy unchanged, still stamp price for observability.
			log.Printf("sidecar[%s]: FAIL-OPEN %s %s price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, price)
			proxy.ServeHTTP(w, r)
			WritePriceHeader(w, price)
		}
	})

	log.Printf("sidecar[%s]: listening on %s, upstream %s (base_price=%.2f scale=%.2f)",
		cfg.ServiceName, cfg.ListenAddr, cfg.UpstreamAddr,
		cfg.BasePrice, cfg.PriceScaleFactor)

	if err := http.ListenAndServe(cfg.ListenAddr, mux); err != nil {
		log.Fatalf("sidecar: server error: %v", err)
	}
}
