package main

import (
	"context"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	cfg := LoadConfigFromEnv()

	// Register Prometheus metrics labelled with this sidecar's service name.
	pm := NewSidecarMetrics(cfg.ServiceName)

	// Shared queue/in-flight counters — updated atomically on every request.
	// pm is attached so every counter change is mirrored to Prometheus gauges.
	metrics := &Metrics{pm: pm}

	// Parse the upstream address into a URL for the reverse proxy.
	upstreamURL, err := url.Parse("http://" + cfg.UpstreamAddr)
	if err != nil {
		log.Fatalf("sidecar: invalid RAJOMON_UPSTREAM_ADDR %q: %v", cfg.UpstreamAddr, err)
	}

	// priceStore maps a per-request context key to the price charged, so ModifyResponse
	// can inject X-Rajomon-Price before headers are flushed downstream.
	// We use a context key to carry the price through the request's context,
	// which survives into the upstream request created by the reverse proxy.
	type priceKey struct{}

	proxy := httputil.NewSingleHostReverseProxy(upstreamURL)
	// ModifyResponse is called by the reverse proxy BEFORE writing the upstream
	// response headers to the client — the correct place to inject our header.
	proxy.ModifyResponse = func(resp *http.Response) error {
		if v := resp.Request.Context().Value(priceKey{}); v != nil {
			WritePriceHeader(resp, v.(float64))
		}
		return nil
	}

	mux := http.NewServeMux()

	// GET /healthz — liveness probe
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// GET /metrics — Prometheus metrics endpoint.
	// Exposes rajomon_sidecar_requests_total, rajomon_sidecar_queued_requests,
	// rajomon_sidecar_in_flight_requests, rajomon_sidecar_admission_price,
	// plus standard Go runtime metrics.
	mux.Handle("/metrics", promhttp.Handler())

	// Catch-all — admission engine + reverse proxy.
	//
	// Request lifecycle (combined queued and in-flight congestion signal):
	//
	//  1. EnqueueRequest()   — request arrives; queue depth rises by 1.
	//  2. GetLocalPrice()    — price = BasePrice + Scale × (queued + in-flight).
	//                          Price is computed AFTER enqueueing so this
	//                          request's own weight is included in the signal.
	//  3. Decide()           — Forward / RejectInsufficientTokens / RejectMissingTokens.
	//
	//  REJECT path:
	//  4. CancelRequest()    — removes request from queue (never enters in-flight).
	//     Returns 503 immediately; upstream never touched.
	//
	//  FORWARD path:
	//  4. DequeueRequest()   — atomically moves request from queue → in-flight.
	//  5. defer CompleteRequest() — decrements in-flight when upstream responds.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Step 1: request enters the queue
		metrics.EnqueueRequest()

		tokens, tokensOK := ReadTokenHeader(r)
		// Internal sidecars: header-less calls (TeaStore does not forward the
		// header) get the configured default budget. Entry sidecar: default 0.
		headerPresent := r.Header.Get(headerTokens) != ""
		tokens, tokensOK = ResolveTokens(headerPresent, tokens, tokensOK, cfg.InternalDefaultTokens)
		// Step 2: price computed from current active load (this request is included)
		price := GetLocalPrice(cfg, metrics)
		cost := AdmissionCost(price)
		verdict := Decide(tokens, tokensOK, price)

		switch verdict {

		case RejectInsufficientTokens:
			// Step 4 (reject): undo the enqueue — request never forwarded.
			metrics.CancelRequest()
			log.Printf("sidecar[%s]: REJECT insufficient-tokens %s %s tokens=%d cost=%d price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, tokens, cost, price)
			pm.RequestsTotal.WithLabelValues("reject_insufficient_tokens").Inc()
			pm.AdmissionPrice.WithLabelValues("reject_insufficient_tokens").Observe(price)
			http.Error(w, "rajomon-http: insufficient tokens for current price",
				http.StatusServiceUnavailable)

		case RejectMissingTokens:
			metrics.CancelRequest()
			log.Printf("sidecar[%s]: REJECT missing-or-invalid-tokens %s %s price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, price)
			pm.RequestsTotal.WithLabelValues("reject_missing_tokens").Inc()
			pm.AdmissionPrice.WithLabelValues("reject_missing_tokens").Observe(price)
			http.Error(w, "rajomon-http: missing or invalid token budget",
				http.StatusUnauthorized)

		case Forward:
			// Step 4 (forward): leave queue, enter in-flight.
			metrics.DequeueRequest()
			defer metrics.CompleteRequest()
			WriteTokenHeader(r, tokens-cost)
			log.Printf("sidecar[%s]: FORWARD %s %s tokens=%d→%d price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, tokens, tokens-cost, price)
			pm.RequestsTotal.WithLabelValues("forward").Inc()
			pm.AdmissionPrice.WithLabelValues("forward").Observe(price)
			// Carry price in the request context so ModifyResponse can inject
			// X-Rajomon-Price before response headers are flushed to the client.
			rWithPrice := r.WithContext(context.WithValue(r.Context(), priceKey{}, price))
			proxy.ServeHTTP(w, rWithPrice)

		}
	})

	log.Printf("sidecar[%s]: listening on %s, upstream %s (base_price=%.2f scale=%.2f, signal=queued_plus_in_flight)",
		cfg.ServiceName, cfg.ListenAddr, cfg.UpstreamAddr,
		cfg.BasePrice, cfg.PriceScaleFactor)

	if err := http.ListenAndServe(cfg.ListenAddr, mux); err != nil {
		log.Fatalf("sidecar: server error: %v", err)
	}
}
