-- spike-price-watch.lua
-- wrk Lua script: sets X-Rajomon-Tokens=50 on every request.
-- Tracks per-thread counts of forward (2xx/3xx) vs reject (503)
-- and collects observed X-Rajomon-Price values on 200 responses.

local token_value = "50"

-- Per-thread state
local forward_count   = 0
local reject_503      = 0
local reject_401      = 0
local price_sum       = 0
local price_count     = 0
local price_min       = math.huge
local price_max       = 0

function setup(thread)
    thread:set("token_value", token_value)
end

function request()
    wrk.headers["X-Rajomon-Tokens"] = token_value
    return wrk.format(nil)
end

function response(status, headers, body)
    if status == 200 or status == 302 then
        forward_count = forward_count + 1
        local price_hdr = headers["X-Rajomon-Price"] or headers["x-rajomon-price"]
        if price_hdr then
            local p = tonumber(price_hdr)
            if p then
                price_sum   = price_sum + p
                price_count = price_count + 1
                if p < price_min then price_min = p end
                if p > price_max then price_max = p end
            end
        end
    elseif status == 503 then
        reject_503 = reject_503 + 1
    elseif status == 401 then
        reject_401 = reject_401 + 1
    end
end

function done(summary, latency, requests)
    local total = forward_count + reject_503 + reject_401
    io.write("\n")
    io.write("┌─────────────────────────────────────────────────────┐\n")
    io.write("│         RAJOMON SPIKE-PRICE-WATCH SUMMARY           │\n")
    io.write("├─────────────────────────────────────────────────────┤\n")
    io.write(string.format("│  tokens budget    : %-32s│\n", token_value))
    io.write(string.format("│  total decided    : %-32d│\n", total))
    io.write(string.format("│  FORWARD (2xx)    : %-32d│\n", forward_count))
    io.write(string.format("│  REJECT 503       : %-32d│\n", reject_503))
    io.write(string.format("│  REJECT 401       : %-32d│\n", reject_401))
    io.write("├─────────────────────────────────────────────────────┤\n")
    if price_count > 0 then
        io.write(string.format("│  observed prices (on 2xx responses)                 │\n"))
        io.write(string.format("│    min price      : %-32.2f│\n", price_min))
        io.write(string.format("│    max price      : %-32.2f│\n", price_max))
        io.write(string.format("│    avg price      : %-32.2f│\n", price_sum / price_count))
        io.write(string.format("│    samples        : %-32d│\n", price_count))
    else
        io.write("│  no 2xx responses — price header not seen           │\n")
    end
    io.write("└─────────────────────────────────────────────────────┘\n")
end
