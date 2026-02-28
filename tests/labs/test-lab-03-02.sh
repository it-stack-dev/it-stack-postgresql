#!/usr/bin/env bash
# test-lab-03-02.sh — Lab 03-02: External Dependencies
# Module 03: PostgreSQL — Streaming Replication
set -euo pipefail

LAB_ID="03-02"
LAB_NAME="Streaming Replication"
COMPOSE_FILE="docker/docker-compose.lan.yml"
PRIMARY_HOST="${PRIMARY_HOST:-localhost}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPLICA_HOST="${REPLICA_HOST:-localhost}"
REPLICA_PORT="${REPLICA_PORT:-5433}"
PGADMIN_URL="${PGADMIN_URL:-http://localhost:5050}"
ADMIN_USER="${ADMIN_USER:-labadmin}"
ADMIN_PASS="${ADMIN_PASS:-Lab02Password!}"
PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()   { echo -e "${GREEN}[PASS]${NC} $1"; ((++PASS)); }
fail()   { echo -e "${RED}[FAIL]${NC} $1"; ((++FAIL)); }
info()   { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

psql_primary() {
  PGPASSWORD="${ADMIN_PASS}" psql \
    -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" \
    -U "${ADMIN_USER}" -d labdb -tAq "$@"
}

psql_replica() {
  PGPASSWORD="${ADMIN_PASS}" psql \
    -h "${REPLICA_HOST}" -p "${REPLICA_PORT}" \
    -U "${ADMIN_USER}" -d labdb -tAq "$@"
}

echo -e "\n${BOLD}IT-Stack Lab ${LAB_ID} — ${LAB_NAME}${NC}"
echo -e "Module 03: PostgreSQL | $(date '+%Y-%m-%d %H:%M:%S')\n"

header "Phase 1: Setup"
info "Starting stack (primary + replica + pgAdmin)..."
docker compose -f "${COMPOSE_FILE}" pull --quiet 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
info "Waiting for primary..."
timeout 90 bash -c "until pg_isready -h ${PRIMARY_HOST} -p ${PRIMARY_PORT} -U ${ADMIN_USER}; do sleep 3; done"
pass "Primary ready"
info "Waiting for replica (base backup ~30s)..."
timeout 120 bash -c "until pg_isready -h ${REPLICA_HOST} -p ${REPLICA_PORT} -U ${ADMIN_USER}; do echo -n '.'; sleep 5; done"
pass "Replica ready"

header "Phase 2: Primary Health"
IN_RECOVERY=$(psql_primary -c "SELECT pg_is_in_recovery();")
if [ "${IN_RECOVERY}" = "f" ]; then
  pass "Primary is NOT in recovery (master)"
else
  fail "Primary unexpectedly in recovery mode"
fi

WAL_LEVEL=$(psql_primary -c "SHOW wal_level;")
if [ "${WAL_LEVEL}" = "replica" ] || [ "${WAL_LEVEL}" = "logical" ]; then
  pass "WAL level = '${WAL_LEVEL}'"
else
  fail "WAL level = '${WAL_LEVEL}' — expected 'replica'"
fi

MAX_WAL=$(psql_primary -c "SHOW max_wal_senders;")
if [ "${MAX_WAL}" -ge 1 ] 2>/dev/null; then
  pass "max_wal_senders=${MAX_WAL}"
else
  fail "max_wal_senders=${MAX_WAL} — replication not configured"
fi

header "Phase 3: Replica Status"
REPLICA_RECOVERY=$(psql_replica -c "SELECT pg_is_in_recovery();")
if [ "${REPLICA_RECOVERY}" = "t" ]; then
  pass "Replica IS in recovery (hot standby)"
else
  fail "Replica is not in recovery mode"
fi

REPCOUNT=$(psql_primary -c "SELECT count(*) FROM pg_stat_replication WHERE state='streaming';")
if [ "${REPCOUNT}" -ge 1 ] 2>/dev/null; then
  pass "pg_stat_replication: ${REPCOUNT} active streaming connection(s)"
else
  warn "No active streaming connections yet (replica may still be syncing)"
fi

header "Phase 4: Data Replication"
psql_primary -c "
  CREATE TABLE IF NOT EXISTS lab02_rep_test (
    id SERIAL PRIMARY KEY, payload TEXT, ts TIMESTAMPTZ DEFAULT now()
  );" > /dev/null

for i in 1 2 3; do
  psql_primary -c "INSERT INTO lab02_rep_test (payload) VALUES ('row-${i}');" > /dev/null
done
pass "Inserted 3 rows into primary"
sleep 3
ROW_COUNT=$(psql_replica -c "SELECT count(*) FROM lab02_rep_test;")
if [ "${ROW_COUNT}" -ge 3 ] 2>/dev/null; then
  pass "Replica has ${ROW_COUNT} rows — replication working"
else
  fail "Replica has ${ROW_COUNT} rows — expected ≥3"
fi

header "Phase 5: Read-Only Enforcement"
WRITE_ERR=$(PGPASSWORD="${ADMIN_PASS}" psql \
  -h "${REPLICA_HOST}" -p "${REPLICA_PORT}" \
  -U "${ADMIN_USER}" -d labdb \
  -c "INSERT INTO lab02_rep_test (payload) VALUES ('should-fail');" \
  2>&1 || true)
if echo "${WRITE_ERR}" | grep -q "read-only\|cannot execute\|recovery"; then
  pass "Replica rejects writes (read-only hot standby)"
else
  fail "Replica accepted a write — misconfigured"
fi

header "Phase 6: Service Databases"
SERVICE_DBS=(keycloak nextcloud mattermost zammad suitecrm odoo openkm taiga snipeit glpi)
for db in "${SERVICE_DBS[@]}"; do
  EXISTS=$(psql_primary -c "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null || echo "")
  if [ "${EXISTS}" = "1" ]; then
    pass "DB '${db}' exists"
  else
    warn "DB '${db}' not found (created when Phase 2 services deploy)"
  fi
done

header "Phase 7: pgAdmin UI"
HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 15 "${PGADMIN_URL}/" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "302" ]; then
  pass "pgAdmin UI reachable (HTTP ${HTTP_CODE})"
else
  warn "pgAdmin returned HTTP ${HTTP_CODE} — may still be starting"
fi

header "Phase 8: Cleanup"
psql_primary -c "DROP TABLE IF EXISTS lab02_rep_test;" > /dev/null
pass "Test table dropped"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
pass "Stack stopped and volumes removed"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Lab ${LAB_ID} Results${NC}"
echo -e "  ${GREEN}Passed:${NC} ${PASS}"
echo -e "  ${RED}Failed:${NC} ${FAIL}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "${FAIL}" -gt 0 ]; then
  echo -e "${RED}FAIL${NC} — ${FAIL} test(s) failed"; exit 1
fi
echo -e "${GREEN}PASS${NC} — All ${PASS} tests passed"