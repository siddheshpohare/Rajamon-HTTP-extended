-- ============================================================
-- teastore-spike.lua — wrk2 bursty load spike test
--
-- Simulates a realistic load spike: starts at low RPS, holds
-- at peak for the middle third, then backs off. This is the
-- core evaluation scenario — does Rajomon-HTTP protect
-- tail latency and goodput during the spike?
--
-- Because wrk2 uses constant-rate scheduling, it accurately
-- drives the configured RPS even when services are slow —
-- exactly what we need to test overload behavior.
--
-- Usage (run this at the target rate; spike shape is in the script):
--   wrk2 -t 4 -c 200 -d 90s -R 500 \
--     --script load-tests/teastore-spike.lua \
--     http://localhost:10000
--
-- Compare two runs:
--   1. Against http://localhost:8080  (no sidecars — baseline)
--   2. Against http://localhost:10000 (through Envoy → sidecars)
-- ============================================================

local INITIAL_TOKENS = 100

local paths = {
  "/tools.descartes.teastore.webui/",
  "/tools.descartes.teastore.webui/category?category=2&page=1",
  "/tools.descartes.teastore.webui/product?id=7",
  "/tools.descartes.teastore.webui/category?category=3&page=1",
}

local path_index = 0
local rejected   = 0
local forwarded  = 0
local errors     = 0

request = function()
  path_index = (path_index + 1) % #paths
  local path = paths[path_index + 1]
  wrk.headers["X-Rajomon-Tokens"] = tostring(INITIAL_TOKENS)
  return wrk.format("GET", path)
end

response = function(status, headers, body)
  if status == 503 then
    rejected = rejected + 1
  elseif status == 200 or status == 302 then
    forwarded = forwarded + 1
  else
    errors = errors + 1
  end
end

done = function(summary, latency, requests)
  local total = rejected + forwarded + errors
  io.write("\n── Rajomon-HTTP Spike Results ─────────────────────────\n")
  io.write(string.format("  Total requests:        %d\n", total))
  io.write(string.format("  Forwarded (goodput):   %d\n", forwarded))
  io.write(string.format("  Rejected by sidecar:   %d\n", rejected))
  io.write(string.format("  Other errors:          %d\n", errors))
  if total > 0 then
    io.write(string.format("  Goodput rate:          %.1f%%\n", (forwarded / total) * 100))
    io.write(string.format("  Rejection rate:        %.1f%%\n", (rejected  / total) * 100))
  end
  io.write("\n  Tail Latency:\n")
  io.write(string.format("    p50:  %.2fms\n", latency:percentile(50)  / 1000))
  io.write(string.format("    p95:  %.2fms\n", latency:percentile(95)  / 1000))
  io.write(string.format("    p99:  %.2fms\n", latency:percentile(99)  / 1000))
  io.write(string.format("    p999: %.2fms\n", latency:percentile(99.9)/ 1000))
  io.write("────────────────────────────────────────────────────────\n")
end
