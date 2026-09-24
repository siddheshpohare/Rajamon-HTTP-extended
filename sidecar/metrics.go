package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// SidecarMetrics holds the Prometheus metric instruments for one sidecar instance.
// All metrics are labelled with the service_name so a single Prometheus config can
// scrape all sidecars and distinguish them in queries.
type SidecarMetrics struct {
	// requestsTotal counts every proxied request, partitioned by verdict.
	// Verdicts: "forward", "forward_fail_open", "reject_insufficient_tokens"
	RequestsTotal *prometheus.CounterVec

	// inFlightRequests is the current number of requests being proxied.
	// Exposed as a gauge so Prometheus can see the real-time congestion signal.
	InFlightRequests prometheus.Gauge

	// admissionPrice records the price charged at the moment of each admission
	// decision. This is a histogram so we can observe price distribution under load.
	AdmissionPrice *prometheus.HistogramVec
}

// NewSidecarMetrics registers all Prometheus metrics for the given service name.
// Must be called exactly once per process.
func NewSidecarMetrics(serviceName string) *SidecarMetrics {
	labels := prometheus.Labels{"service_name": serviceName}

	return &SidecarMetrics{
		RequestsTotal: promauto.NewCounterVec(
			prometheus.CounterOpts{
				Namespace:   "rajomon",
				Subsystem:   "sidecar",
				Name:        "requests_total",
				Help:        "Total requests processed by the sidecar, partitioned by verdict.",
				ConstLabels: labels,
			},
			[]string{"verdict"},
		),

		InFlightRequests: promauto.NewGauge(
			prometheus.GaugeOpts{
				Namespace:   "rajomon",
				Subsystem:   "sidecar",
				Name:        "in_flight_requests",
				Help:        "Current number of requests being proxied by this sidecar.",
				ConstLabels: labels,
			},
		),

		AdmissionPrice: promauto.NewHistogramVec(
			prometheus.HistogramOpts{
				Namespace:   "rajomon",
				Subsystem:   "sidecar",
				Name:        "admission_price",
				Help:        "Price charged at the moment of each admission decision.",
				ConstLabels: labels,
				// Buckets cover the range from base_price (1.0) up through high-load prices
				Buckets: []float64{0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 20.0, 50.0},
			},
			[]string{"verdict"},
		),
	}
}
