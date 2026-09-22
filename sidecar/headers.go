package main

import (
	"fmt"
	"net/http"
	"strconv"
)

const (
	headerTokens = "X-Rajomon-Tokens"
	headerPrice  = "X-Rajomon-Price"
)

// ReadTokenHeader parses the X-Rajomon-Tokens request header as an integer.
// ok=false if the header is missing or not a valid integer.
func ReadTokenHeader(r *http.Request) (tokens int, ok bool) {
	raw := r.Header.Get(headerTokens)
	if raw == "" {
		return 0, false
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return 0, false
	}
	return v, true
}

// WriteTokenHeader sets X-Rajomon-Tokens on the outgoing (proxied) request
// to reflect the remaining token budget after deducting the current price.
func WriteTokenHeader(r *http.Request, remaining int) {
	r.Header.Set(headerTokens, strconv.Itoa(remaining))
}

// WritePriceHeader sets X-Rajomon-Price on the response, formatted to 2
// decimal places, so the caller can observe the price charged at this hop.
func WritePriceHeader(w http.ResponseWriter, price float64) {
	w.Header().Set(headerPrice, fmt.Sprintf("%.2f", price))
}
