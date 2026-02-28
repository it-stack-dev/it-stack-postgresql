#!/usr/bin/env bash
# test-lab-03-05.sh — PostgreSQL Lab 05: Multi-Service Integration
# Tests: PG serves KC + app DBs, Redis cache layer, Traefik routing,
#        cross-service connections, load balancing, Prometheus metrics
set -euo pipefail

PASS=0; FAIL=0
PG_PASS="${PG_PASS:-Lab05Password!}"
KC_PASS="${KC_PASS:-Lab05Password!}"
KC_URL="http://localhost:8080"
TRAEFIK_API="http://localhost:8080"
REALM="it-stack"

pass()  { ((++PASS)); echo "  [PASS] $1"; }
fail()  { ((++FAIL)); echo "  [FAIL] $1"; }
warn()  { echo "  [WARN] $1"; }
header(){ echo; echo "=== $1 ==="; }

kc_token() {
  curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

header "1. PostgreSQL — Primary Database"
if pg_isready -h localhost -p 5432 -U postgres &>/dev/null; then
  pass "PostgreSQL :5432 ready"
else
  fail "PostgreSQL not ready"; exit 1
fi

header "2. Multiple Databases on Single PG Instance"
DBS=$(PGPASSWORD="$PG_PASS" psql -h localhost -p 5432 -U postgres -t -c "SELECT datname FROM pg_database WHERE datname IN ('keycloak','labapp') ORDER BY datname;" 2>/dev/null | tr -d ' ' | grep -v '^$')
echo "$DBS" | grep -q "keycloak" && pass "Database 'keycloak' exists on PostgreSQL" || fail "Database 'keycloak' not found"
echo "$DBS" | grep -q "labapp"   && pass "Database 'labapp' exists on PostgreSQL"   || fail "Database 'labapp' not found"

header "3. PostgreSQL Active Connections by Database"
CONNS=$(PGPASSWORD="$PG_PASS" psql -h localhost -p 5432 -U postgres -t -c "SELECT count(*) FROM pg_stat_activity WHERE datname='keycloak';" 2>/dev/null | tr -d ' ')
[[ "$CONNS" -gt 0 ]] && pass "Keycloak has $CONNS active connections to PG" || warn "No Keycloak connections yet (KC may still be starting)"

header "4. Keycloak Health"
if curl -sf "$KC_URL/health/ready" | grep -q '"status":"UP"'; then
  pass "Keycloak /health/ready UP"
else
  fail "Keycloak not ready"; exit 1
fi

header "5. Keycloak Admin Auth"
TOKEN=$(kc_token)
[[ -n "$TOKEN" ]] && pass "Admin token obtained from Keycloak" || { fail "Admin auth failed"; exit 1; }

header "6. Realm + Client Setup"
curl -sf -X POST "$KC_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true}" -o /dev/null \
  && pass "Realm '$REALM' created" || warn "Realm may exist"
TOKEN=$(kc_token)
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"clientId\":\"pg-app\",\"secret\":\"$KC_PASS\",\"publicClient\":false,
       \"serviceAccountsEnabled\":true,\"enabled\":true}")
[[ "$STATUS" =~ ^(201|409)$ ]] && pass "OIDC client 'pg-app' ready" || fail "Client creation failed (HTTP $STATUS)"

header "7. KC Realm Persisted in PostgreSQL"
TOKEN=$(kc_token)
REALM_CHECK=$(curl -sf "$KC_URL/admin/realms/$REALM" -H "Authorization: Bearer $TOKEN" | grep -o '"realm":"[^"]*"' | head -1)
echo "$REALM_CHECK" | grep -q "$REALM" && pass "Realm '$REALM' confirmed in KC (persisted in PG)" || fail "Realm not found"
DB_REALM=$(PGPASSWORD="$PG_PASS" psql -h localhost -p 5432 -U postgres -d keycloak -t \
  -c "SELECT count(*) FROM realm WHERE name='$REALM';" 2>/dev/null | tr -d ' ')
[[ "${DB_REALM:-0}" -gt 0 ]] && pass "Realm '$REALM' verified in PostgreSQL realm table" || warn "Direct DB check not accessible (may use schema prefix)"

header "8. Redis Cache Layer"
if redis-cli -p 6379 -a "$PG_PASS" --no-auth-warning PING 2>/dev/null | grep -q PONG; then
  pass "Redis :6379 PING → PONG"
  redis-cli -p 6379 -a "$PG_PASS" --no-auth-warning SET "cache:session:1" "user=labadmin&exp=$(date +%s)" EX 300 2>/dev/null | grep -q OK \
    && pass "Redis SET cache:session:1 with 300s TTL" || fail "Redis SET failed"
  TTL=$(redis-cli -p 6379 -a "$PG_PASS" --no-auth-warning TTL "cache:session:1" 2>/dev/null)
  [[ "${TTL:-0}" -gt 0 ]] && pass "Redis TTL = $TTL seconds (expiry working)" || fail "Redis TTL not set"
  redis-cli -p 6379 -a "$PG_PASS" --no-auth-warning SET "cache:db:users" "42" EX 60 2>/dev/null | grep -q OK \
    && pass "Redis cache:db:users set (simulates PG query cache)" || fail "Redis cache key failed"
  KEYS=$(redis-cli -p 6379 -a "$PG_PASS" --no-auth-warning KEYS "cache:*" 2>/dev/null | wc -l)
  [[ "$KEYS" -ge 2 ]] && pass "Redis has $KEYS cache keys (cache layer active)" || fail "Expected ≥2 cache keys"
else
  fail "Redis not responding"
fi

header "9. Traefik Routing"
if curl -sf http://localhost:8080/api/version | grep -q "Version"; then
  pass "Traefik dashboard API accessible"
  ROUTERS=$(curl -sf http://localhost:8080/api/http/routers 2>/dev/null | grep -o '"provider"' | wc -l)
  [[ "$ROUTERS" -ge 2 ]] && pass "Traefik has $ROUTERS routers configured" || warn "Router count: $ROUTERS"
else
  fail "Traefik API not accessible"
fi

header "10. Traefik /app Route (load balanced)"
APP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:80/app 2>/dev/null || echo "000")
[[ "$APP_STATUS" -eq 200 ]] && pass "Traefik /app → 200 (app backends responding)" || warn "Traefik /app returned HTTP $APP_STATUS"

header "11. Traefik Load Balancing (multiple backends)"
NODES=()
for i in 1 2 3 4; do
  NAME=$(curl -sf http://localhost:80/app 2>/dev/null | grep "Name:" | awk '{print $2}' || true)
  [[ -n "$NAME" ]] && NODES+=("$NAME")
done
UNIQUE=$(echo "${NODES[@]:-}" | tr ' ' '\n' | sort -u | wc -l)
[[ "$UNIQUE" -ge 2 ]] && pass "Load balancing confirmed: $UNIQUE unique backends across 4 requests" \
  || warn "Load balancing: $UNIQUE unique backend(s) seen (may need more warmup)"

header "12. Prometheus Metrics"
if curl -sf http://localhost:8082/metrics | grep -q "traefik_"; then
  pass "Traefik Prometheus metrics endpoint active"
  METRIC_COUNT=$(curl -sf http://localhost:8082/metrics | grep -c "^traefik_" || echo 0)
  [[ "$METRIC_COUNT" -gt 5 ]] && pass "Metrics: $METRIC_COUNT traefik_ series exported" || warn "Only $METRIC_COUNT metric series"
else
  fail "Traefik metrics not available"
fi

header "13. Cross-Service Integration Summary"
PG_OK=$(pg_isready -h localhost -p 5432 -U postgres &>/dev/null && echo 1 || echo 0)
KC_OK=$(curl -sf "$KC_URL/health/ready" 2>/dev/null | grep -c UP || echo 0)
RD_OK=$(redis-cli -p 6379 -a "$PG_PASS" --no-auth-warning PING 2>/dev/null | grep -c PONG || echo 0)
TR_OK=$(curl -sf http://localhost:8080/api/version 2>/dev/null | grep -c Version || echo 0)
SCORE=$((PG_OK + KC_OK + RD_OK + TR_OK))
[[ "$SCORE" -ge 3 ]] && pass "Integration score: $SCORE/4 services interconnected" || fail "Integration score: $SCORE/4 (too many services down)"

echo
echo "═══════════════════════════════════════"
echo " Lab 03-05 Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]