package main

import (
	"sync/atomic"
)

// Metrics holds the per-sidecar runtime counters used for price computation.
// All fields are accessed atomically so the struct is safe for concurrent use.
//
// Phase 4: pm is the Prometheus SidecarMetrics used to mirror every counter
// change into Prometheus instruments so /metrics serves live data.
type Metrics struct {
	InFlight int64           // current number of requests being proxied (atomic)
	pm       *SidecarMetrics // Prometheus instruments (set once at startup)
}

// IncInFlight atomically increments the in-flight counter and mirrors the
// change to the Prometheus gauge.
// Called at the start of every proxied request.
func (m *Metrics) IncInFlight() {
	atomic.AddInt64(&m.InFlight, 1)
	if m.pm != nil {
		m.pm.InFlightRequests.Inc()
	}
}

// DecInFlight atomically decrements the in-flight counter and mirrors the
// change to the Prometheus gauge.
// Called (via defer) at the end of every proxied request.
func (m *Metrics) DecInFlight() {
	atomic.AddInt64(&m.InFlight, -1)
	if m.pm != nil {
		m.pm.InFlightRequests.Dec()
	}
}

// GetLocalPrice returns the current admission price for this service instance:
//
//	price = BasePrice + PriceScaleFactor × in_flight
//
// In-flight request count is the congestion signal: simple, real, and
// well-established (same principle as concurrency-based load-shedding
// libraries used in production systems).
func GetLocalPrice(cfg SidecarConfig, m *Metrics) float64 {
	inFlight := atomic.LoadInt64(&m.InFlight)
	return cfg.BasePrice + cfg.PriceScaleFactor*float64(inFlight)
}
