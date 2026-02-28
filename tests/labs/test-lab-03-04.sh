#!/usr/bin/env bash
# test-lab-03-04.sh — PostgreSQL Lab 04: SSO via Keycloak OIDC + oauth2-proxy
# Tests: Keycloak realm/client/user setup, OIDC discovery, client_credentials
#        token, JWT validation, oauth2-proxy SSO gate, PostgreSQL connectivity
set -euo pipefail

PASS=0; FAIL=0
KC_PASS="${KC_PASS:-Lab04Password!}"
KC_URL="http://localhost:8080"
REALM="it-stack"

pass()  { ((++PASS)); echo "  [PASS] $1"; }
fail()  { ((++FAIL)); echo "  [FAIL] $1"; }
warn()  { echo "  [WARN] $1"; }
header(){ echo; echo "=== $1 ==="; }

# ── Helper: get admin token ───────────────────────────────────────────
kc_token() {
  curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

header "1. Keycloak Health"
if curl -sf "$KC_URL/health/ready" | grep -q '"status":"UP"'; then
  pass "Keycloak /health/ready UP"
else
  fail "Keycloak not ready"; exit 1
fi

header "2. Admin Authentication"
TOKEN=$(kc_token)
[[ -n "$TOKEN" ]] && pass "Admin token obtained" || { fail "Admin token failed"; exit 1; }

header "3. Realm Setup"
curl -sf -X POST "$KC_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true,\"displayName\":\"IT-Stack\"}" \
  -o /dev/null && pass "Realm '$REALM' created" || warn "Realm may already exist"

TOKEN=$(kc_token)

header "4. OIDC Client Registration"
curl -sf -X POST "$KC_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"clientId\":\"oauth2-proxy\",\"secret\":\"$KC_PASS\",\"publicClient\":false,
       \"serviceAccountsEnabled\":true,\"redirectUris\":[\"http://localhost:4180/*\"],
       \"enabled\":true}" \
  -o /dev/null && pass "Client 'oauth2-proxy' created" || warn "Client may already exist"

TOKEN=$(kc_token)

header "5. Test User Creation"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"username\":\"labuser\",\"enabled\":true,\"email\":\"labuser@lab.local\",
       \"emailVerified\":true,
       \"credentials\":[{\"type\":\"password\",\"value\":\"$KC_PASS\",\"temporary\":false}]}")
[[ "$STATUS" =~ ^(201|409)$ ]] && pass "Test user 'labuser' ready (HTTP $STATUS)" || fail "User creation failed (HTTP $STATUS)"

header "6. Client Credentials Token (service account)"
TOKEN=$(kc_token)
SA_TOKEN=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "client_id=oauth2-proxy&client_secret=${KC_PASS}&grant_type=client_credentials" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$SA_TOKEN" ]] && pass "Service account token obtained" || fail "Service account token failed"

header "7. JWT Structure Validation"
IFS='.' read -ra JWT_PARTS <<< "$SA_TOKEN"
[[ "${#JWT_PARTS[@]}" -eq 3 ]] && pass "JWT has 3 parts (header.payload.signature)" || fail "Invalid JWT structure"

if [[ "${#JWT_PARTS[@]}" -eq 3 ]]; then
  PAYLOAD=$(echo "${JWT_PARTS[1]}" | base64 -d 2>/dev/null || echo "${JWT_PARTS[1]}" | base64 --decode 2>/dev/null || true)
  echo "$PAYLOAD" | grep -q '"iss"' && pass "JWT payload has 'iss' claim" || fail "JWT missing 'iss' claim"
  echo "$PAYLOAD" | grep -q '"exp"' && pass "JWT payload has 'exp' claim" || fail "JWT missing 'exp' claim"
fi

header "8. OIDC Discovery Endpoint"
DISCOVERY=$(curl -sf "$KC_URL/realms/$REALM/.well-known/openid-configuration")
echo "$DISCOVERY" | grep -q '"token_endpoint"' && pass "Discovery: token_endpoint present" || fail "Discovery missing token_endpoint"
echo "$DISCOVERY" | grep -q '"authorization_endpoint"' && pass "Discovery: authorization_endpoint present" || fail "Discovery missing authorization_endpoint"
echo "$DISCOVERY" | grep -q '"jwks_uri"' && pass "Discovery: jwks_uri present" || fail "Discovery missing jwks_uri"
echo "$DISCOVERY" | grep -q '"userinfo_endpoint"' && pass "Discovery: userinfo_endpoint present" || fail "Discovery missing userinfo_endpoint"

header "9. UserInfo Endpoint"
UI_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $SA_TOKEN" "$KC_URL/realms/$REALM/protocol/openid-connect/userinfo")
[[ "$UI_STATUS" =~ ^(200|400)$ ]] && pass "UserInfo endpoint responds (HTTP $UI_STATUS)" || fail "UserInfo endpoint failed (HTTP $UI_STATUS)"

header "10. Token Introspection"
TOKEN=$(kc_token)
INTRO=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token/introspect" \
  -u "oauth2-proxy:${KC_PASS}" \
  -d "token=${SA_TOKEN}" | grep -o '"active":[a-z]*' | head -1)
echo "$INTRO" | grep -q '"active":true' && pass "Token introspection: active=true" || fail "Token not active"

header "11. JWKS Endpoint"
JWKS_URL=$(echo "$DISCOVERY" | grep -o '"jwks_uri":"[^"]*"' | cut -d'"' -f4)
curl -sf "$JWKS_URL" | grep -q '"keys"' && pass "JWKS endpoint returns keys" || fail "JWKS endpoint failed"

header "12. oauth2-proxy SSO Gate"
if curl -sf --max-time 5 http://localhost:4180/ping -o /dev/null 2>/dev/null; then
  pass "oauth2-proxy /ping responds"
  REDIR=$(curl -s -o /dev/null -w "%{http_code}" --max-redirect 0 http://localhost:4180/ 2>/dev/null || true)
  [[ "$REDIR" =~ ^(302|307)$ ]] && pass "oauth2-proxy redirects to Keycloak (HTTP $REDIR)" || warn "oauth2-proxy responded with $REDIR"
else
  warn "oauth2-proxy not started yet (requires client to exist first)"
fi

header "13. PostgreSQL Connectivity"
if pg_isready -h localhost -p 5432 -U labadmin &>/dev/null; then
  pass "PostgreSQL port 5432 ready"
  PGPASSWORD="$KC_PASS" psql -h localhost -p 5432 -U labadmin -d labdb -c "SELECT 1 AS sso_lab" -t 2>/dev/null \
    | grep -q "1" && pass "PostgreSQL query via labdb succeeds" || fail "PostgreSQL query failed"
else
  fail "PostgreSQL not ready"
fi

echo
echo "═══════════════════════════════════════"
echo " Lab 03-04 Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]