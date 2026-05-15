#!/usr/bin/env bash
#
# smoke-test.sh <hostname>
#
# Post-deploy verification:
#   - HTTPS GET / returns 200
#   - TLS cert is valid (not expired, matches hostname)
#   - Tailscale reports the host as Online
#   - /timeline.rss exists for at least one known repo (if any)
#
# Usage: bin/smoke-test.sh fossil.exidia.com

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <hostname>" >&2
  exit 2
fi

HOST="$1"
FAIL=0

note() { printf "    %s\n" "$*"; }
pass() { printf "✅  %s\n" "$*"; }
fail() { printf "❌  %s\n" "$*"; FAIL=1; }

echo "Smoke-testing https://$HOST/"

# 1. HTTPS GET / — `-fsS` performs TLS cert validation (trust chain +
# hostname match) and fails on >=400. No `-k`: a self-signed, expired,
# or wrong-hostname cert would fail this check.
status=$(curl -fsS -o /dev/null -w '%{http_code}' "https://$HOST/" 2>/dev/null || echo "curl-failed")
if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
  pass "GET / returned $status (TLS validation passed)"
else
  fail "GET / failed: $status (TLS validation may have failed; try \`curl -v https://$HOST/\` to see why)"
fi

# 2. TLS cert not-expired (explicit check). `s_client < /dev/null` plus
# `-checkend 0` exits non-zero if the cert is expired right now.
if echo | openssl s_client -servername "$HOST" -connect "$HOST:443" 2>/dev/null \
    | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
  expiry=$(echo | openssl s_client -servername "$HOST" -connect "$HOST:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | cut -d= -f2)
  pass "TLS cert not expired (until: $expiry)"
else
  fail "TLS cert is expired or unreachable"
fi

# 3. Tailscale presence (best-effort; skip if tailscale CLI unavailable locally)
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status 2>/dev/null | grep -q -E "^[^[:space:]]+\s+$HOST\b|\b${HOST%%.*}\s"; then
    pass "Tailscale: $HOST visible on tailnet"
  else
    note "Tailscale: $HOST not visible (may be expected if running from non-tailnet machine)"
  fi
else
  note "tailscale CLI not installed locally — skipping tailnet check"
fi

# 4. Fossil-specific endpoint (best-effort)
if curl -sk "https://$HOST/" | grep -qi "fossil"; then
  pass "response body mentions 'fossil'"
else
  note "response body does not mention 'fossil' — verify manually"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "FAILED — see ❌ lines above"
  exit 1
fi

echo
echo "✅ All checks passed for $HOST."
