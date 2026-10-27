-- ============================================================
-- teastore-baseline.lua — wrk2 baseline load test
--
-- Plain HTTP load against TeaStore WebUI with NO Rajomon headers.
-- Use this to establish the uncontrolled baseline: no admission
-- control, no token deduction. Compare against teastore-rajomon.lua.
--
-- Usage:
--   wrk2 -t 4 -c 50 -d 60s -R 200 \
--     --script load-tests/teastore-baseline.lua \
--     http://localhost:8080
--
-- Target: teastore-webui direct on :8080 (bypass sidecars entirely)
-- ============================================================

-- Rotate across a set of representative TeaStore endpoints
local paths = {
  "/tools.descartes.teastore.webui/",
  "/tools.descartes.teastore.webui/category?category=2&page=1",
  "/tools.descartes.teastore.webui/product?id=7",
  "/tools.descartes.teastore.webui/login",
}

local path_index = 0

request = function()
  path_index = (path_index + 1) % #paths
  local path = paths[path_index + 1]
  return wrk.format("GET", path)
end

response = function(status, headers, body)
  if status ~= 200 and status ~= 302 then
    io.write("non-200: " .. status .. "\n")
  end
end
