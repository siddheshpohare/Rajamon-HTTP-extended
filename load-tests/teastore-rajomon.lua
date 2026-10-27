-- ============================================================
-- teastore-rajomon.lua — wrk2 Rajomon-HTTP load test
--
-- HTTP load against TeaStore with X-Rajomon-Tokens header attached.
-- Routes through Envoy Gateway → sidecar-webui → teastore-webui.
-- Admission control is ACTIVE: sidecars may return 503 when tokens
-- are insufficient for the current price.
--
-- Usage (permissive gateway — tokens survive):
--   wrk2 -t 4 -c 50 -d 60s -R 200 \
--     --script load-tests/teastore-rajomon.lua \
--     http://localhost:10000
--
-- Tune INITIAL_TOKENS to test sensitivity to budget size.
-- ============================================================

local INITIAL_TOKENS = 100   -- Starting token budget per request

-- Same endpoint rotation as baseline — A/B comparison is meaningful
local paths = {
  "/tools.descartes.teastore.webui/",
  "/tools.descartes.teastore.webui/category?category=2&page=1",
  "/tools.descartes.teastore.webui/product?id=7",
  "/tools.descartes.teastore.webui/login",
}

local path_index = 0
local rejected   = 0
local forwarded  = 0

request = function()
  path_index = (path_index + 1) % #paths
  local path = paths[path_index + 1]
  -- Attach token budget — sidecar reads this and makes admission decision
  wrk.headers["X-Rajomon-Tokens"] = tostring(INITIAL_TOKENS)
  return wrk.format("GET", path)
end

response = function(status, headers, body)
  if status == 503 then
    rejected = rejected + 1
  elseif status == 200 or status == 302 then
    forwarded = forwarded + 1
  end
end

done = function(summary, latency, requests)
  local total = rejected + forwarded
  io.write("\n── Rajomon-HTTP Results ───────────────────────────────\n")
  io.write(string.format("  Forwarded (admitted):  %d\n", forwarded))
  io.write(string.format("  Rejected (503):        %d\n", rejected))
  if total > 0 then
    io.write(string.format("  Rejection rate:        %.1f%%\n", (rejected / total) * 100))
  end
  io.write(string.format("  p50 latency:           %.2fms\n", latency:percentile(50) / 1000))
  io.write(string.format("  p95 latency:           %.2fms\n", latency:percentile(95) / 1000))
  io.write(string.format("  p99 latency:           %.2fms\n", latency:percentile(99) / 1000))
  io.write("────────────────────────────────────────────────────────\n")
end
