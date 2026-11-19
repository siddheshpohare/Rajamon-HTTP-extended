package main

import "math"

// Verdict is the result of the admission decision for a single request.
type Verdict int

const (
	// Forward: tokens are present and cover the integer admission cost.
	Forward Verdict = iota

	// RejectInsufficientTokens: a valid token budget cannot cover the cost.
	// Respond immediately with 503 — upstream is never touched.
	RejectInsufficientTokens

	// RejectMissingTokens: the token header is missing or malformed. This
	// prevents a request whose header was stripped by a gateway from reaching
	// the protected upstream.
	RejectMissingTokens
)

// Decide implements strict admission:
//
//	tokens present & valid? | tokens vs. price | Verdict                  | Upstream touched?
//	------------------------|------------------|--------------------------|------------------
//	No                      | —                | RejectMissingTokens      | No
//	Yes                     | tokens >= cost   | Forward                  | Yes
//	Yes                     | tokens < cost    | RejectInsufficientTokens | No
//
// Cost is ceil(price), so integer token budgets never underpay a fractional
// congestion price.
func Decide(tokens int, tokensOK bool, price float64) Verdict {
	if !tokensOK {
		return RejectMissingTokens
	}
	if tokens >= AdmissionCost(price) {
		return Forward
	}
	return RejectInsufficientTokens
}

// AdmissionCost converts the local floating-point price to the integer token
// charge used for both the admission check and deduction.
func AdmissionCost(price float64) int {
	if price <= 0 {
		return 0
	}
	return int(math.Ceil(price))
}
