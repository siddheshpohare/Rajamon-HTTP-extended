package main

import (
	"sync/atomic"
)

// Metrics holds the per-sidecar runtime counters used for price computation.
// All fields are accessed atomically so the struct is safe for concurrent use.
//
// Congestion signal: queue depth — the number of requests that have arrived at
// this sidecar's handler but have not yet started being proxied to the upstream.
// This is a tighter signal than raw in-flight count because it directly measures
// backpressure: a growing queue means the upstream is slower than arrival rate.
//
// How it works:
//   - Queued is incremented when a request enters the handler (before admission).
//   - Queued is decremented (and InFlight incremented) the moment the request
//     passes admission and starts being forwarded to the upstream.
//   - InFlight is decremented (via defer) when the upstream response returns.
//
// This gives:  queue_depth = Queued  (waiting for upstream capacity)
//              in_flight   = InFlight (actively being proxied)
//
// pm is the Prometheus SidecarMetrics used to mirror every counter change
// into Prometheus instruments so /metrics serves live data.
type Metrics struct {
	Queued   int64           // requests waiting in queue (not yet forwarded) (atomic)
	InFlight int64           // requests currently being proxied to upstream (atomic)
	pm       *SidecarMetrics // Prometheus instruments (set once at startup)
}

// EnqueueRequest atomically increments the queue counter when a request
// arrives at the handler, before the admission decision is made.
func (m *Metrics) EnqueueRequest() {
	atomic.AddInt64(&m.Queued, 1)
	if m.pm != nil {
		m.pm.QueuedRequests.Inc()
	}
}

// DequeueRequest atomically decrements the queue counter and increments the
// in-flight counter when a request passes admission and starts being proxied.
func (m *Metrics) DequeueRequest() {
	atomic.AddInt64(&m.Queued, -1)
	atomic.AddInt64(&m.InFlight, 1)
	if m.pm != nil {
		m.pm.QueuedRequests.Dec()
		m.pm.InFlightRequests.Inc()
	}
}

// CompleteRequest atomically decrements the in-flight counter when the
// upstream response has been returned. Called via defer after forwarding.
func (m *Metrics) CompleteRequest() {
	atomic.AddInt64(&m.InFlight, -1)
	if m.pm != nil {
		m.pm.InFlightRequests.Dec()
	}
}

// CancelRequest atomically decrements the queue counter when a request is
// rejected by the admission engine (before it ever started being proxied).
// Paired with EnqueueRequest — called in the RejectInsufficientTokens path.
func (m *Metrics) CancelRequest() {
	atomic.AddInt64(&m.Queued, -1)
	if m.pm != nil {
		m.pm.QueuedRequests.Dec()
	}
}

// GetLocalPrice returns the current admission price for this service instance:
//
//	price = BasePrice + PriceScaleFactor × queue_depth
//
// Queue depth is the congestion signal: it measures how many requests are
// waiting to be forwarded. A non-zero queue means the upstream is already
// saturated — the price rises to deter further arrivals, shedding load
// before it accumulates. This is a more direct overload signal than raw
// in-flight count because it captures backpressure, not just concurrency.
func GetLocalPrice(cfg SidecarConfig, m *Metrics) float64 {
	queued := atomic.LoadInt64(&m.Queued)
	if queued < 0 {
		queued = 0 // guard against transient underflow during startup
	}
	return cfg.BasePrice + cfg.PriceScaleFactor*float64(queued)
}
