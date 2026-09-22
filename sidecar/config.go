package main

import (
	"log"
	"os"
	"strconv"
)

// SidecarConfig holds all environment-sourced configuration for a sidecar instance.
type SidecarConfig struct {
	// ServiceName identifies this sidecar in logs and metrics (e.g. "compose-post-service")
	ServiceName string
	// ListenAddr is the address the sidecar HTTP server binds to (e.g. ":9464")
	ListenAddr string
	// UpstreamAddr is the host:port of the real service this sidecar proxies to
	// (e.g. "compose-post-service:9090")
	UpstreamAddr string

	// ── Phase 3: Admission engine pricing ────────────────────────────────────
	// BasePrice is the minimum price this service charges even at zero load.
	// Sourced from RAJOMON_BASE_PRICE; default 1.0.
	BasePrice float64
	// PriceScaleFactor controls how steeply price rises per in-flight request.
	// Sourced from RAJOMON_PRICE_SCALE_FACTOR; default 0.5.
	PriceScaleFactor float64
}

// LoadConfigFromEnv reads all required and optional env vars.
// Exits non-zero if any required variable is missing.
func LoadConfigFromEnv() SidecarConfig {
	cfg := SidecarConfig{
		ServiceName:  os.Getenv("RAJOMON_SERVICE_NAME"),
		ListenAddr:   os.Getenv("RAJOMON_LISTEN_ADDR"),
		UpstreamAddr: os.Getenv("RAJOMON_UPSTREAM_ADDR"),
	}

	missing := []string{}
	if cfg.ServiceName == "" {
		missing = append(missing, "RAJOMON_SERVICE_NAME")
	}
	if cfg.ListenAddr == "" {
		missing = append(missing, "RAJOMON_LISTEN_ADDR")
	}
	if cfg.UpstreamAddr == "" {
		missing = append(missing, "RAJOMON_UPSTREAM_ADDR")
	}

	if len(missing) > 0 {
		log.Fatalf("sidecar: missing required environment variable(s): %v", missing)
	}

	// ── Phase 3: pricing parameters (optional, with safe defaults) ───────────
	cfg.BasePrice = parseFloatEnv("RAJOMON_BASE_PRICE", 1.0)
	cfg.PriceScaleFactor = parseFloatEnv("RAJOMON_PRICE_SCALE_FACTOR", 0.5)

	return cfg
}

// parseFloatEnv returns the float64 value of the named env var, or defaultVal
// if the variable is unset or empty. Exits non-zero if the value is set but
// not a valid float, to catch misconfigured experiments early.
func parseFloatEnv(name string, defaultVal float64) float64 {
	raw := os.Getenv(name)
	if raw == "" {
		return defaultVal
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		log.Fatalf("sidecar: env var %s=%q is not a valid float: %v", name, raw, err)
	}
	return v
}
