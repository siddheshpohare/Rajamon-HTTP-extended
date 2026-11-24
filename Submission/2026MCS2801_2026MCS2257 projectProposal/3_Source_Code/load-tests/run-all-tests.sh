#!/usr/bin/env bash
################################################################################
# run-all-tests.sh - Rajomon-HTTP end-to-end test runner (bash)
#
# Runs, in order:
#   T1  Go unit tests (in a golang container)
#   T2  Health of all 5 sidecars
#   T3  TeaStore registry advertises the sidecars (internal calls go via them)
#   T4  Entry-sidecar verdicts (200 / 503 / 401), ceil() rule, Envoy gateway
#   T5  Internal-sidecar verdicts (default 20-token budget for header-less calls)
#   T6  Browse the shop once -> all 5 sidecar counters must increase
#   T7  Prometheus sees all 5 sidecar targets UP
#   T8  Steady load (default 200 req/s, tokens=100, 30 s) - NOT a spike
#   T9  Post-load: queued / in-flight gauges back to 0, internal sidecars were hit
#
# Usage:
#   ./load-tests/run-all-tests.sh                 # stack already running
#   ./load-tests/run-all-tests.sh --up            # start the stack first
#   ./load-tests/run-all-tests.sh --skip-load     # functional checks only
#   ./load-tests/run-all-tests.sh --skip-unit     # skip the Go unit tests
#   RATE=100 DURATION=20s TOKENS=100 ./load-tests/run-all-tests.sh
#
# Env vars: HOST (localhost) RATE (200) DURATION (30s) TOKENS (100)
#           MIN_SUCCESS (95, percent of 2xx/3xx required in T8)
# Exit code: 0 = every check passed, 1 = at least one check failed.
################################################################################

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${HOST:-localhost}"
RATE="${RATE:-200}"
DURATION="${DURATION:-30s}"
TOKENS="${TOKENS:-100}"
MIN_SUCCESS="${MIN_SUCCESS:-95}"

DO_UP=0; DO_UNIT=1; DO_LOAD=1
for a in "$@"; do
  case "$a" in
    --up) DO_UP=1 ;;
    --skip-unit) DO_UNIT=0 ;;
    --skip-load) DO_LOAD=0 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'; else G=; R=; Y=; C=; N=; fi
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ${G}[PASS]${N} $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ${R}[FAIL]${N} $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ${Y}[SKIP]${N} $1"; }
hdr()  { echo; echo "${C}=== $1 ===${N}"; }
expect() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1 (got $3)"; else bad "$1 (expected $2, got $3)"; fi
}
contains() { # name haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (expected to contain '$3', got '$2')" ;; esac
}
code() { curl -s -m 20 -o /dev/null -w '%{http_code}' "$@"; }
# value of a counter/gauge line; prints integer (handles scientific notation)
fwd()   { curl -s -m 5 "http://$HOST:$1/metrics" | awk '/^rajomon_sidecar_requests_total/ && /verdict="forward"/ {s+=$2} END{printf "%d", s}'; }
gauge() { curl -s -m 5 "http://$HOST:$1/metrics" | awk -v m="$2" '$1 ~ "^"m"\\{" {s+=$2} END{printf "%d", s}'; }
reg()   { curl -s -m 5 "http://$HOST:8083/tools.descartes.teastore.registry/rest/services/tools.descartes.teastore.$1/"; }

WEBUI="http://$HOST:9550/tools.descartes.teastore.webui/"
PERSIST="http://$HOST:9554/tools.descartes.teastore.persistence/rest/categories"
PORTS="9550 9551 9552 9553 9554"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
command -v curl   >/dev/null || { echo "curl not found";   exit 1; }

# -------------------------------------------------------------- optional start
if [ "$DO_UP" = 1 ]; then
  hdr "Starting the stack (docker compose --profile permissive up -d --build)"
  ( cd "$ROOT" && { [ -f .env ] || cp .env.example .env; } && docker compose --profile permissive up -d --build ) || { echo "compose up failed"; exit 1; }
fi

hdr "Waiting for TeaStore to be ready (up to ~5 min)"
n=0
until [ "$(code -H "X-Rajomon-Tokens: 100" "$WEBUI")" = "200" ] && \
      [ "$(reg persistence)" != "[]" ] && [ -n "$(reg persistence)" ] && \
      [ "$(reg recommender)" != "[]" ] && [ "$(reg image)" != "[]" ] && [ "$(reg auth)" != "[]" ]; do
  n=$((n+1)); [ $n -ge 50 ] && { echo "${R}stack not ready - is it running? (docker compose --profile permissive ps)${N}"; exit 1; }
  sleep 6
done
echo "ready"

# ------------------------------------------------------------------ T1 unit
hdr "T1  Go unit tests"
if [ "$DO_UNIT" = 1 ]; then
  SRC="$(cd "$ROOT/sidecar" && (pwd -W 2>/dev/null || pwd))"
  OUT="$(MSYS_NO_PATHCONV=1 docker run --rm -v "$SRC:/src" -w /src golang:1.26 sh -c "go vet ./... && go test ./... -v" 2>&1)"
  RC=$?
  NPASS=$(echo "$OUT" | grep -c -E '^\s*--- PASS')
  NFAIL=$(echo "$OUT" | grep -c -E '^\s*--- FAIL')
  if [ $RC -eq 0 ] && [ "$NFAIL" = 0 ]; then ok "go vet + go test ($NPASS test/sub-test PASS lines, 0 FAIL)"; else bad "unit tests failed"; echo "$OUT" | tail -20; fi
else skip "unit tests (--skip-unit)"; fi

# ------------------------------------------------------------------ T2 health
hdr "T2  Sidecar health"
for p in $PORTS; do expect "healthz :$p" 200 "$(code "http://$HOST:$p/healthz")"; done

# ------------------------------------------------------------------ T3 registry
hdr "T3  Registry advertises the sidecars (config-only interception)"
contains "auth        registers teastore-auth:9551"                "$(reg auth)"        "teastore-auth:9551"
contains "imageprovider registers teastore-imageprovider:9552"    "$(reg image)"       "teastore-imageprovider:9552"
contains "recommender registers teastore-recommender:9553"        "$(reg recommender)" "teastore-recommender:9553"
contains "persistence registers teastore-persistence:9554"        "$(reg persistence)" "teastore-persistence:9554"

# ------------------------------------------------------------------ T4 entry
hdr "T4  Entry sidecar (strict policy) - sidecar-webui :9550"
HDRS="$(curl -si -m 20 -H 'X-Rajomon-Tokens: 100' "$WEBUI")"
contains "tokens=100 -> 200"                 "$(echo "$HDRS" | head -1)" " 200"
contains "response carries X-Rajomon-Price"  "$(echo "$HDRS" | tr 'A-Z' 'a-z')" "x-rajomon-price:"
expect "tokens=0   -> 503 (insufficient)"    503 "$(code -H 'X-Rajomon-Tokens: 0' "$WEBUI")"
expect "no header  -> 401 (strict)"          401 "$(code "$WEBUI")"
expect "tokens=abc -> 401 (malformed)"       401 "$(code -H 'X-Rajomon-Tokens: abc' "$WEBUI")"
expect "tokens=1   -> 503 (ceil(1.5)=2)"     503 "$(code -H 'X-Rajomon-Tokens: 1' "$WEBUI")"
expect "tokens=2   -> 200 (exact cost)"      200 "$(code -H 'X-Rajomon-Tokens: 2' "$WEBUI")"
if [ "$(code "http://$HOST:9901/ready")" = "200" ]; then
  expect "via Envoy :10000 tokens=100 -> 200" 200 "$(code -H 'X-Rajomon-Tokens: 100' "http://$HOST:10000/tools.descartes.teastore.webui/")"
else skip "Envoy not running (start with: docker compose --profile permissive up -d)"; fi

# ------------------------------------------------------------------ T5 internal
hdr "T5  Internal sidecar (default 20-token budget) - sidecar-persistence :9554"
expect "no header     -> 200 (default budget)" 200 "$(code "$PERSIST")"
expect "tokens=1      -> 503"                  503 "$(code -H 'X-Rajomon-Tokens: 1' "$PERSIST")"
expect "tokens=abc    -> 401 (malformed)"      401 "$(code -H 'X-Rajomon-Tokens: abc' "$PERSIST")"

# ------------------------------------------------------------------ T6 browse
hdr "T6  Browse the shop once - every sidecar counter must increase"
for p in $PORTS; do eval "B_$p=$(fwd $p)"; done
for u in "" "category?category=2&page=1" "product?id=7" "login" "cart"; do
  c=$(code -H 'X-Rajomon-Tokens: 100' "http://$HOST:9550/tools.descartes.teastore.webui/$u")
  expect "GET /$u via :9550" 200 "$c"
done
sleep 3
for p in $PORTS; do
  A=$(fwd $p)
  b=$(eval echo "$B_$p"); if [ "$A" -gt "$b" ]; then ok "sidecar :$p forward count $b -> $A"; else bad "sidecar :$p did not move ($b -> $A)"; fi
done

# ------------------------------------------------------------------ T7 prometheus
hdr "T7  Prometheus targets"
if [ "$(code "http://$HOST:9090/-/ready")" = "200" ]; then
  UP=$(curl -s -m 10 -G "http://$HOST:9090/api/v1/query" --data-urlencode 'query=count(up{job="rajomon_sidecars"}==1)' | grep -o '"value":\[[^]]*\]' | sed 's/.*,"\([0-9]*\)".*/\1/')
  expect "sidecar targets UP in Prometheus" 5 "${UP:-0}"
else skip "Prometheus not reachable on :9090"; fi

# ------------------------------------------------------------------ T8 load
hdr "T8  Steady load: ${RATE} req/s, tokens=${TOKENS}, ${DURATION} (not a spike)"
if [ "$DO_LOAD" = 1 ]; then
  for p in $PORTS; do eval "B_$p=$(fwd $p)"; done
  REPORT=""
  if MSYS_NO_PATHCONV=1 docker run --rm peterevans/vegeta vegeta -version >/dev/null 2>&1; then
    echo "  tool: vegeta (constant arrival rate)"
    REPORT="$(echo "GET $WEBUI" | MSYS_NO_PATHCONV=1 docker run --rm -i --network host peterevans/vegeta sh -c \
      "vegeta attack -rate=${RATE} -duration=${DURATION} -timeout=15s -header 'X-Rajomon-Tokens: ${TOKENS}' | vegeta report")"
    echo "$REPORT" | sed 's/^/  /'
    SUCC=$(echo "$REPORT" | awk '/^Success/ {gsub("%","",$3); print $3}')
  else
    echo "  ${Y}vegeta image unavailable - falling back to a paced curl generator (rate may be lower)${N}"
    SECS=${DURATION%s}; CODES="$(mktemp)"
    for ((s=0; s<SECS; s++)); do
      t0=$(date +%s%N)
      seq "$RATE" | xargs -P 100 -I{} curl -s -m 15 -o /dev/null -w '%{http_code}\n' -H "X-Rajomon-Tokens: ${TOKENS}" "$WEBUI" >> "$CODES"
      el=$(( ($(date +%s%N) - t0) / 1000000 )); [ $el -lt 1000 ] && sleep "0.$(printf '%03d' $((1000-el)))"
    done
    TOT=$(wc -l < "$CODES"); OKN=$(grep -c -E '^(2|3)' "$CODES")
    echo "  sent=$TOT  2xx/3xx=$OKN"; sort "$CODES" | uniq -c | sed 's/^/  /'
    SUCC=$(awk -v a="$OKN" -v b="$TOT" 'BEGIN{ if(b>0) printf "%.2f", a*100/b; else print 0 }'); rm -f "$CODES"
  fi
  if [ -n "${SUCC:-}" ] && awk -v s="$SUCC" -v m="$MIN_SUCCESS" 'BEGIN{exit !(s+0>=m+0)}'; then
    ok "success ratio ${SUCC}% >= ${MIN_SUCCESS}% at ~${RATE} req/s with tokens=${TOKENS}"
  else bad "success ratio '${SUCC:-n/a}%' < ${MIN_SUCCESS}% (host too slow? lower RATE)"; fi
else skip "load test (--skip-load)"; fi

# ------------------------------------------------------------------ T9 post
hdr "T9  After the load: counters healthy"
sleep 6
for p in $PORTS; do
  q=$(gauge $p rajomon_sidecar_queued_requests); i=$(gauge $p rajomon_sidecar_in_flight_requests)
  if [ "$q" = 0 ] && [ "$i" = 0 ]; then ok "sidecar :$p queued=0 in_flight=0"; else bad "sidecar :$p queued=$q in_flight=$i (leak?)"; fi
done
if [ "$DO_LOAD" = 1 ]; then
  for p in 9551 9552 9553 9554; do
    A=$(fwd $p); b=$(eval echo "$B_$p"); if [ "$A" -gt "$b" ]; then ok "internal sidecar :$p handled load ($b -> $A forwards)"; else bad "internal sidecar :$p saw no load traffic"; fi
  done
fi

# ------------------------------------------------------------------ summary
hdr "Summary"
echo "  passed: $PASS   failed: $FAIL   skipped: $SKIP"
echo
echo "  Show the graphs now: Grafana  http://$HOST:3000  (dashboard 'Rajomon-HTTP - Sidecar Fleet Overview', time range 'Last 15 minutes')"
echo "                       Prometheus http://$HOST:9090/graph"
echo "  (see TESTING_GUIDE.md, last section)"
[ "$FAIL" = 0 ] && { echo "  ${G}ALL CHECKS PASSED${N}"; exit 0; } || { echo "  ${R}SOME CHECKS FAILED${N}"; exit 1; }
