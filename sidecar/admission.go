package main

// Verdict is the result of the admission decision for a single request.
type Verdict int

const (
	// Forward: tokens present and tokens >= price.
	// Deduct price, proxy the request, attach price header to response.
	Forward Verdict = iota

	// RejectInsufficientTokens: tokens present but tokens < price.
	// Respond immediately with 503 — upstream is never touched.
	RejectInsufficientTokens

	// ForwardFailOpen: no X-Rajomon-Tokens header (or unparseable).
	// Proxy the request unchanged (no token accounting), still attach price header.
	ForwardFailOpen
)

// Decide implements the Phase 3 Decision Table exactly as specified:
//
//	tokens present & valid? | tokens vs. price | Verdict                  | Upstream touched?
//	------------------------|------------------|--------------------------|------------------
//	No                      | —                | ForwardFailOpen          | Yes
//	Yes                     | tokens >= price  | Forward                  | Yes
//	Yes                     | tokens < price   | RejectInsufficientTokens | No
//
// Do not add additional cases or thresholds not listed in the table above.
func Decide(tokens int, tokensOK bool, price float64) Verdict {
	if !tokensOK {
		return ForwardFailOpen
	}
	if float64(tokens) >= price {
		return Forward
	}
	return RejectInsufficientTokens
}
