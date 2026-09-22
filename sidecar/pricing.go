package main

import (
	"sync/atomic"
)

// Metrics holds the per-sidecar runtime counters used for price computation.
// All fields are accessed atomically so the struct is safe for concurrent use.
type Metrics struct {
	InFlight int64 // current number of requests being proxied
}

// IncInFlight atomically increments the in-flight counter.
// Called at the start of every proxied request.
func (m *Metrics) IncInFlight() {
	atomic.AddInt64(&m.InFlight, 1)
}

// DecInFlight atomically decrements the in-flight counter.
// Called (via defer) at the end of every proxied request.
func (m *Metrics) DecInFlight() {
	atomic.AddInt64(&m.InFlight, -1)
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
