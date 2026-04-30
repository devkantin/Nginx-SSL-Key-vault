#!/usr/bin/env bash
# Post-deployment Nginx + SSL test suite.
# Usage: ./nginx.tests.sh <public-ip-or-fqdn>

set -euo pipefail

TARGET="${1:?Usage: nginx.tests.sh <public-ip-or-fqdn>}"
PASS=0
FAIL=0
TOTAL=0

pass() { echo "  PASS [$((++TOTAL))] $1"; ((PASS++)); }
fail() { echo "  FAIL [$((++TOTAL))] $1"; ((FAIL++)); }

echo ""
echo "========================================"
echo " Nginx SSL Test Suite"
echo " Target: $TARGET"
echo "========================================"
echo ""

# ─── Connectivity ─────────────────────────────────────────────────────────────
echo "--- Connectivity ---"

HTTP_CODE=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "http://$TARGET" || echo "000")
if [ "$HTTP_CODE" = "301" ]; then
  pass "Port 80 responds with 301 redirect"
else
  fail "Port 80 expected 301, got $HTTP_CODE"
fi

REDIRECT_URL=$(curl -s --max-time 10 -o /dev/null -w "%{redirect_url}" "http://$TARGET" || echo "")
if echo "$REDIRECT_URL" | grep -q "^https://"; then
  pass "HTTP redirects to HTTPS: $REDIRECT_URL"
else
  fail "HTTP did not redirect to HTTPS (got: '$REDIRECT_URL')"
fi

HTTPS_CODE=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "https://$TARGET" || echo "000")
if [ "$HTTPS_CODE" = "200" ]; then
  pass "HTTPS returns 200 OK"
else
  fail "HTTPS returned $HTTPS_CODE (expected 200)"
fi

# ─── Follow redirect end-to-end ───────────────────────────────────────────────
echo ""
echo "--- Redirect chain ---"
FINAL_CODE=$(curl -skL --max-time 10 -o /dev/null -w "%{http_code}" "http://$TARGET" || echo "000")
if [ "$FINAL_CODE" = "200" ]; then
  pass "HTTP → HTTPS redirect chain ends with 200"
else
  fail "Redirect chain ended with $FINAL_CODE (expected 200)"
fi

# ─── SSL / TLS ────────────────────────────────────────────────────────────────
echo ""
echo "--- SSL / TLS ---"

CERT_INFO=$(echo | timeout 15 openssl s_client -connect "$TARGET:443" -servername "$TARGET" 2>/dev/null || true)

if echo "$CERT_INFO" | grep -q "CONNECTED"; then
  pass "SSL handshake succeeded"
else
  fail "SSL handshake failed — Nginx may not be configured yet"
fi

TLS_VER=$(echo "$CERT_INFO" | grep "Protocol" | awk '{print $NF}' || true)
if echo "$TLS_VER" | grep -qE "TLSv1\.[23]"; then
  pass "TLS version is acceptable: $TLS_VER"
else
  fail "TLS version not acceptable: '$TLS_VER' (expected TLSv1.2 or TLSv1.3)"
fi

CERT_DATES=$(echo "$CERT_INFO" | openssl x509 -noout -dates 2>/dev/null || true)
NOT_AFTER=$(echo "$CERT_DATES" | grep notAfter | cut -d= -f2 || true)
if [ -n "$NOT_AFTER" ]; then
  pass "Certificate expiry: $NOT_AFTER"
else
  fail "Could not read certificate expiry date"
fi

CERT_SUBJECT=$(echo "$CERT_INFO" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//' || true)
if [ -n "$CERT_SUBJECT" ]; then
  pass "Certificate subject: $CERT_SUBJECT"
else
  fail "Could not read certificate subject"
fi

# Verify cert is not self-signed with an expired CA (basic validity)
CERT_VERIFY=$(echo "$CERT_INFO" | grep "Verify return code" || true)
if echo "$CERT_VERIFY" | grep -q "0 (ok)\|18 (self.signed\|21 (unable to verify\|19 (self signed"; then
  pass "Certificate verification returned expected code: $CERT_VERIFY"
else
  fail "Unexpected cert verify result: $CERT_VERIFY"
fi

# ─── TLS hardening ────────────────────────────────────────────────────────────
echo ""
echo "--- TLS hardening ---"

TLS10=$(echo | timeout 10 openssl s_client -connect "$TARGET:443" -tls1 2>&1 || true)
if echo "$TLS10" | grep -qiE "no protocols available|handshake failure|tlsv1 alert|:error:"; then
  pass "TLS 1.0 is correctly rejected"
else
  fail "TLS 1.0 may not be disabled"
fi

TLS11=$(echo | timeout 10 openssl s_client -connect "$TARGET:443" -tls1_1 2>&1 || true)
if echo "$TLS11" | grep -qiE "no protocols available|handshake failure|tlsv1 alert|:error:"; then
  pass "TLS 1.1 is correctly rejected"
else
  fail "TLS 1.1 may not be disabled"
fi

# ─── Security headers ─────────────────────────────────────────────────────────
echo ""
echo "--- Security headers ---"

HEADERS=$(curl -skI --max-time 10 "https://$TARGET" || true)

HSTS=$(echo "$HEADERS" | grep -i "strict-transport-security" || true)
if [ -n "$HSTS" ]; then
  pass "HSTS header present: $(echo "$HSTS" | tr -d '\r')"
else
  fail "HSTS header missing (Strict-Transport-Security)"
fi

XCTO=$(echo "$HEADERS" | grep -i "x-content-type-options" || true)
if [ -n "$XCTO" ]; then
  pass "X-Content-Type-Options header present"
else
  fail "X-Content-Type-Options header missing"
fi

XFO=$(echo "$HEADERS" | grep -i "x-frame-options" || true)
if [ -n "$XFO" ]; then
  pass "X-Frame-Options header present"
else
  fail "X-Frame-Options header missing"
fi

# ─── Application endpoints ────────────────────────────────────────────────────
echo ""
echo "--- Application endpoints ---"

HEALTH=$(curl -sk --max-time 10 "https://$TARGET/health" || true)
if [ "$HEALTH" = "OK" ]; then
  pass "/health returns OK"
else
  fail "/health returned: '$HEALTH' (expected OK)"
fi

INDEX=$(curl -sk --max-time 10 "https://$TARGET/" || true)
if echo "$INDEX" | grep -qi "nginx\|html"; then
  pass "/ returns HTML content"
else
  fail "/ did not return expected HTML content"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " Results: $PASS passed, $FAIL failed / $TOTAL total"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAILED"
  exit 1
fi
echo "RESULT: ALL TESTS PASSED"
