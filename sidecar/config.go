package main

import (
	"log"
	"os"
)

// SidecarConfig holds the three required environment variables for a sidecar instance.
type SidecarConfig struct {
	// ServiceName identifies this sidecar in logs and metrics (e.g. "compose-post-service")
	ServiceName string
	// ListenAddr is the address the sidecar HTTP server binds to (e.g. ":9464")
	ListenAddr string
	// UpstreamAddr is the host:port of the real service this sidecar proxies to
	// (e.g. "compose-post-service:9090")
	UpstreamAddr string
}

// LoadConfigFromEnv reads the three required env vars and exits non-zero if any is missing.
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

	return cfg
}
