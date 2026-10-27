package main

import (
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

	proxy := httputil.NewSingleHostReverseProxy(upstreamURL)

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
	// Request lifecycle (queue-depth congestion signal):
	//
	//  1. EnqueueRequest()   — request arrives; queue depth rises by 1.
	//  2. GetLocalPrice()    — price = BasePrice + Scale × queue_depth.
	//                          Price is computed AFTER enqueueing so this
	//                          request's own weight is included in the signal.
	//  3. Decide()           — Forward / RejectInsufficientTokens / ForwardFailOpen.
	//
	//  REJECT path:
	//  4. CancelRequest()    — removes request from queue (never enters in-flight).
	//     Returns 503 immediately; upstream never touched.
	//
	//  FORWARD / FAIL-OPEN path:
	//  4. DequeueRequest()   — atomically moves request from queue → in-flight.
	//  5. defer CompleteRequest() — decrements in-flight when upstream responds.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Step 1: request enters the queue
		metrics.EnqueueRequest()

		tokens, tokensOK := ReadTokenHeader(r)
		// Step 2: price computed from current queue depth (this request is included)
		price := GetLocalPrice(cfg, metrics)
		verdict := Decide(tokens, tokensOK, price)

		switch verdict {

		case RejectInsufficientTokens:
			// Step 4 (reject): undo the enqueue — request never forwarded.
			metrics.CancelRequest()
			log.Printf("sidecar[%s]: REJECT %s %s tokens=%d price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, tokens, price)
			pm.RequestsTotal.WithLabelValues("reject_insufficient_tokens").Inc()
			pm.AdmissionPrice.WithLabelValues("reject_insufficient_tokens").Observe(price)
			http.Error(w, "rajomon-http: insufficient tokens for current price",
				http.StatusServiceUnavailable)

		case Forward:
			// Step 4 (forward): leave queue, enter in-flight.
			metrics.DequeueRequest()
			defer metrics.CompleteRequest()
			WriteTokenHeader(r, tokens-int(price))
			log.Printf("sidecar[%s]: FORWARD %s %s tokens=%d→%d price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, tokens, tokens-int(price), price)
			pm.RequestsTotal.WithLabelValues("forward").Inc()
			pm.AdmissionPrice.WithLabelValues("forward").Observe(price)
			proxy.ServeHTTP(w, r)
			WritePriceHeader(w, price)

		case ForwardFailOpen:
			// Step 4 (fail-open): leave queue, enter in-flight.
			metrics.DequeueRequest()
			defer metrics.CompleteRequest()
			log.Printf("sidecar[%s]: FAIL-OPEN %s %s price=%.2f",
				cfg.ServiceName, r.Method, r.URL.Path, price)
			pm.RequestsTotal.WithLabelValues("forward_fail_open").Inc()
			pm.AdmissionPrice.WithLabelValues("forward_fail_open").Observe(price)
			proxy.ServeHTTP(w, r)
			WritePriceHeader(w, price)
		}
	})

	log.Printf("sidecar[%s]: listening on %s, upstream %s (base_price=%.2f scale=%.2f, signal=queue_depth)",
		cfg.ServiceName, cfg.ListenAddr, cfg.UpstreamAddr,
		cfg.BasePrice, cfg.PriceScaleFactor)

	if err := http.ListenAndServe(cfg.ListenAddr, mux); err != nil {
		log.Fatalf("sidecar: server error: %v", err)
	}
}
