package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// SidecarMetrics holds the Prometheus metric instruments for one sidecar instance.
// All metrics are labelled with the service_name so a single Prometheus config can
// scrape all sidecars and distinguish them in queries.
type SidecarMetrics struct {
	// RequestsTotal counts every request processed, partitioned by verdict.
	// Verdicts: "forward", "forward_fail_open", "reject_insufficient_tokens"
	RequestsTotal *prometheus.CounterVec

	// QueuedRequests is the current number of requests waiting in the sidecar's
	// queue — arrived at the handler but not yet forwarded to the upstream.
	// This is the congestion signal that drives price computation.
	// A rising queue means the upstream is slower than the arrival rate.
	QueuedRequests prometheus.Gauge

	// InFlightRequests is the current number of requests actively being proxied
	// to the upstream (post-admission, waiting for the upstream response).
	// Kept for observability — not used for price computation.
	InFlightRequests prometheus.Gauge

	// AdmissionPrice records the price charged at the moment of each admission
	// decision. Histogram so we can observe price distribution under load.
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

		QueuedRequests: promauto.NewGauge(
			prometheus.GaugeOpts{
				Namespace:   "rajomon",
				Subsystem:   "sidecar",
				Name:        "queued_requests",
				Help:        "Current number of requests waiting in the sidecar queue (arrived but not yet forwarded). This is the price congestion signal.",
				ConstLabels: labels,
			},
		),

		InFlightRequests: promauto.NewGauge(
			prometheus.GaugeOpts{
				Namespace:   "rajomon",
				Subsystem:   "sidecar",
				Name:        "in_flight_requests",
				Help:        "Current number of requests actively being proxied to the upstream (post-admission).",
				ConstLabels: labels,
			},
		),

		AdmissionPrice: promauto.NewHistogramVec(
			prometheus.HistogramOpts{
				Namespace:   "rajomon",
				Subsystem:   "sidecar",
				Name:        "admission_price",
				Help:        "Price charged at the moment of each admission decision (driven by queue depth).",
				ConstLabels: labels,
				// Buckets cover base_price (1.0) up through high-load prices
				Buckets: []float64{0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 20.0, 50.0},
			},
			[]string{"verdict"},
		),
	}
}
