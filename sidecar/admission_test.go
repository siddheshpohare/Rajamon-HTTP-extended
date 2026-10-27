package main

import "testing"

// TestDecide covers every row of the Decision Table.
// The admission logic itself is unchanged — only the congestion signal
// (queue depth vs. in-flight) that feeds into price has changed.
func TestDecide(t *testing.T) {
	tests := []struct {
		name     string
		tokens   int
		tokensOK bool
		price    float64
		want     Verdict
	}{
		// Row 1: No header → fail-open (upstream touched, no accounting)
		{
			name:     "no token header → ForwardFailOpen",
			tokens:   0,
			tokensOK: false,
			price:    1.0,
			want:     ForwardFailOpen,
		},
		// Row 2: tokens present, tokens >= price → Forward
		{
			name:     "tokens exactly equal to price → Forward",
			tokens:   5,
			tokensOK: true,
			price:    5.0,
			want:     Forward,
		},
		{
			name:     "tokens greater than price → Forward",
			tokens:   100,
			tokensOK: true,
			price:    1.5,
			want:     Forward,
		},
		// Row 3: tokens present, tokens < price → Reject
		{
			name:     "tokens less than price → RejectInsufficientTokens",
			tokens:   0,
			tokensOK: true,
			price:    1.0,
			want:     RejectInsufficientTokens,
		},
		{
			name:     "tokens much less than price → RejectInsufficientTokens",
			tokens:   3,
			tokensOK: true,
			price:    10.0,
			want:     RejectInsufficientTokens,
		},
		// Edge: fail-open even when token value happens to be 0
		{
			name:     "missing header with zero-value token → ForwardFailOpen",
			tokens:   0,
			tokensOK: false,
			price:    0.0,
			want:     ForwardFailOpen,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Decide(tt.tokens, tt.tokensOK, tt.price)
			if got != tt.want {
				t.Errorf("Decide(%d, %v, %v) = %v, want %v",
					tt.tokens, tt.tokensOK, tt.price, got, tt.want)
			}
		})
	}
}

// TestGetLocalPrice verifies that GetLocalPrice uses queue depth (not in-flight)
// as its congestion signal, and that the formula is correct.
func TestGetLocalPrice(t *testing.T) {
	cfg := SidecarConfig{
		BasePrice:        1.0,
		PriceScaleFactor: 0.5,
	}

	tests := []struct {
		name       string
		queued     int64
		inFlight   int64
		wantPrice  float64
	}{
		{
			name:      "zero queue, zero in-flight → base price only",
			queued:    0,
			inFlight:  0,
			wantPrice: 1.0,
		},
		{
			name:      "queue=2, in-flight=0 → price driven by queue",
			queued:    2,
			inFlight:  0,
			wantPrice: 2.0, // 1.0 + 0.5*2
		},
		{
			name:      "queue=0, in-flight=10 → price NOT driven by in-flight",
			queued:    0,
			inFlight:  10,
			wantPrice: 1.0, // in-flight does NOT affect price
		},
		{
			name:      "queue=10, in-flight=3 → only queue matters",
			queued:    10,
			inFlight:  3,
			wantPrice: 6.0, // 1.0 + 0.5*10
		},
		{
			name:      "negative queued (transient underflow) → clamped to base price",
			queued:    -2,
			inFlight:  0,
			wantPrice: 1.0, // underflow guard: queued clamped to 0
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := &Metrics{
				Queued:   tt.queued,
				InFlight: tt.inFlight,
			}
			got := GetLocalPrice(cfg, m)
			if got != tt.wantPrice {
				t.Errorf("GetLocalPrice() = %.2f, want %.2f (queued=%d, in_flight=%d)",
					got, tt.wantPrice, tt.queued, tt.inFlight)
			}
		})
	}
}

// TestMetricsLifecycle verifies the counter transitions across the full
// request lifecycle for each verdict path.
func TestMetricsLifecycle(t *testing.T) {
	t.Run("forward path: enqueue → dequeue → complete", func(t *testing.T) {
		m := &Metrics{}
		m.EnqueueRequest()
		if m.Queued != 1 || m.InFlight != 0 {
			t.Errorf("after EnqueueRequest: Queued=%d InFlight=%d, want 1,0", m.Queued, m.InFlight)
		}
		m.DequeueRequest()
		if m.Queued != 0 || m.InFlight != 1 {
			t.Errorf("after DequeueRequest: Queued=%d InFlight=%d, want 0,1", m.Queued, m.InFlight)
		}
		m.CompleteRequest()
		if m.Queued != 0 || m.InFlight != 0 {
			t.Errorf("after CompleteRequest: Queued=%d InFlight=%d, want 0,0", m.Queued, m.InFlight)
		}
	})

	t.Run("reject path: enqueue → cancel (never in-flight)", func(t *testing.T) {
		m := &Metrics{}
		m.EnqueueRequest()
		if m.Queued != 1 {
			t.Errorf("after EnqueueRequest: Queued=%d, want 1", m.Queued)
		}
		m.CancelRequest()
		if m.Queued != 0 || m.InFlight != 0 {
			t.Errorf("after CancelRequest: Queued=%d InFlight=%d, want 0,0", m.Queued, m.InFlight)
		}
	})

	t.Run("concurrent requests accumulate in queue", func(t *testing.T) {
		m := &Metrics{}
		for i := 0; i < 5; i++ {
			m.EnqueueRequest()
		}
		if m.Queued != 5 {
			t.Errorf("Queued=%d after 5 enqueues, want 5", m.Queued)
		}
		// Two admitted, three still queued
		m.DequeueRequest()
		m.DequeueRequest()
		if m.Queued != 3 || m.InFlight != 2 {
			t.Errorf("Queued=%d InFlight=%d, want 3,2", m.Queued, m.InFlight)
		}
	})
}
