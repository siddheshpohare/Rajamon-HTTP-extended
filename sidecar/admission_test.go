package main

import "testing"

// TestDecide covers every row of the Phase 3 Decision Table.
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
