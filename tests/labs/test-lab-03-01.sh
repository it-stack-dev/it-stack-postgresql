#!/usr/bin/env bash
# test-lab-03-01.sh — Lab 03-01: Standalone
# Module 03: PostgreSQL primary database
# Basic postgresql functionality in complete isolation
set -euo pipefail

LAB_ID="03-01"
LAB_NAME="Standalone"
MODULE="postgresql"
COMPOSE_FILE="docker/docker-compose.standalone.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((++PASS)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((++FAIL)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────
PG_HOST=localhost
PG_PORT=5432
ADMIN_USER=labadmin
ADMIN_PASS=Lab01Password!
APP_USER=appuser
APP_PASS=AppPass123!
TEST_USER=testuser
TEST_PASS=TestPass123!

psql_admin() {
  PGPASSWORD="${ADMIN_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" \
    -U "${ADMIN_USER}" -d labdb -t -c "$1" 2>/dev/null
}

psql_as() {
  local user="$1" pass="$2" db="$3" query="$4"
  PGPASSWORD="${pass}" psql -h "${PG_HOST}" -p "${PG_PORT}" \
    -U "${user}" -d "${db}" -t -c "${query}" 2>/dev/null
}

psql_check() {
  local user="$1" pass="$2" db="$3" query="$4" test_name="$5"
  if PGPASSWORD="${pass}" psql -h "${PG_HOST}" -p "${PG_PORT}" \
      -U "${user}" -d "${db}" -t -c "${query}" > /dev/null 2>&1; then
    pass "${test_name}"
  else
    fail "${test_name}"
  fi
}

wait_for_postgres() {
  local retries=30
  until PGPASSWORD="${ADMIN_PASS}" pg_isready -h "${PG_HOST}" -p "${PG_PORT}" \
    -U "${ADMIN_USER}" > /dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ "${retries}" -le 0 ]]; then
      fail "PostgreSQL did not become ready within 150 seconds"
      return 1
    fi
    info "Waiting for PostgreSQL... (${retries} retries left)"
    sleep 5
  done
  pass "PostgreSQL is ready"
}

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"  
docker compose -f "${COMPOSE_FILE}" pull --quiet 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
info "Waiting for PostgreSQL to be ready..."
wait_for_postgres

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

# Container running
if docker compose -f "${COMPOSE_FILE}" ps postgresql | grep -qE "running|Up|healthy"; then
  pass "Container is running"
else
  fail "Container is not running"
fi

# Docker healthcheck status
HEALTH=$(docker inspect --format='{{.State.Health.Status}}' it-stack-postgresql-lab01 2>/dev/null)
if [[ "${HEALTH}" == "healthy" ]]; then
  pass "Docker healthcheck reports healthy"
else
  warn "Docker healthcheck status: ${HEALTH} (may still be starting)"
fi

# Port is open
if nc -z -w3 "${PG_HOST}" "${PG_PORT}" 2>/dev/null; then
  pass "Port ${PG_PORT} is open"
else
  fail "Port ${PG_PORT} is not reachable"
fi

# pg_isready
if PGPASSWORD="${ADMIN_PASS}" pg_isready -h "${PG_HOST}" -p "${PG_PORT}" \
    -U "${ADMIN_USER}" > /dev/null 2>&1; then
  pass "pg_isready confirms server accepting connections"
else
  fail "pg_isready returned non-zero"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests"

# 3.1 Admin connection
info "3.1 — Admin connection"
psql_check "${ADMIN_USER}" "${ADMIN_PASS}" labdb "SELECT version();" \
  "Admin user can connect to labdb"

# 3.2 PostgreSQL version
PG_VER=$(psql_admin "SELECT split_part(version(), ' ', 2);" | tr -d '[:space:]')
if [[ "${PG_VER}" == 16* ]]; then
  pass "PostgreSQL version is 16.x (got: ${PG_VER})"
else
  fail "Expected PostgreSQL 16.x, got: ${PG_VER}"
fi

# 3.3 Databases exist
info "3.3 — Database existence"
for db in labdb appdb testdb; do
  if psql_admin "SELECT 1 FROM pg_database WHERE datname='${db}';" \
      | grep -q "1"; then
    pass "Database '${db}' exists"
  else
    fail "Database '${db}' not found"
  fi
done

# 3.4 Users exist
info "3.4 — User existence"
for u in appuser testuser; do
  if psql_admin "SELECT 1 FROM pg_roles WHERE rolname='${u}';" \
      | grep -q "1"; then
    pass "User '${u}' exists"
  else
    fail "User '${u}' not found"
  fi
done

# 3.5 User authentication
info "3.5 — User authentication"
psql_check "${APP_USER}" "${APP_PASS}" appdb "SELECT current_user;" \
  "appuser authenticates to appdb"
psql_check "${TEST_USER}" "${TEST_PASS}" testdb "SELECT current_user;" \
  "testuser authenticates to testdb"

# 3.6 Sample table and data from init script
info "3.6 — Init script data"
if psql_admin "SELECT count(*) FROM it_stack_lab;" \
    | grep -qE "[0-9]+"; then
  pass "it_stack_lab table exists and has rows"
else
  fail "it_stack_lab table missing or empty (init script may have failed)"
fi

# 3.7 CRUD operations
info "3.7 — CRUD operations"
# INSERT
psql_check "${ADMIN_USER}" "${ADMIN_PASS}" labdb \
  "INSERT INTO it_stack_lab (module, lab_number, status) VALUES ('test','00-00','created');" \
  "INSERT row into it_stack_lab"

# SELECT with filter
if psql_admin "SELECT id FROM it_stack_lab WHERE status='created';" \
    | grep -qE "[0-9]+"; then
  pass "SELECT with WHERE filter works"
else
  fail "SELECT with WHERE filter returned no results"
fi

# UPDATE
psql_check "${ADMIN_USER}" "${ADMIN_PASS}" labdb \
  "UPDATE it_stack_lab SET status='updated' WHERE lab_number='00-00';" \
  "UPDATE row in it_stack_lab"

if psql_admin "SELECT 1 FROM it_stack_lab WHERE status='updated';" \
    | grep -q "1"; then
  pass "UPDATE confirmed via SELECT"
else
  fail "UPDATE not reflected in SELECT"
fi

# DELETE
psql_check "${ADMIN_USER}" "${ADMIN_PASS}" labdb \
  "DELETE FROM it_stack_lab WHERE lab_number='00-00';" \
  "DELETE row from it_stack_lab"

# 3.8 Transaction test
info "3.8 — Transaction support"
if PGPASSWORD="${ADMIN_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" \
    -U "${ADMIN_USER}" -d labdb > /dev/null 2>&1 <<'SQL'
BEGIN;
  INSERT INTO it_stack_lab (module, lab_number, status) VALUES ('txtest','00-99','txpending');
  UPDATE it_stack_lab SET status='txcommitted' WHERE lab_number='00-99';
COMMIT;
SQL
then
  pass "Transaction BEGIN/COMMIT succeeds"
else
  fail "Transaction failed"
fi
psql_admin "DELETE FROM it_stack_lab WHERE lab_number='00-99';" > /dev/null 2>&1 || true

# Transaction ROLLBACK
if PGPASSWORD="${ADMIN_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" \
    -U "${ADMIN_USER}" -d labdb > /dev/null 2>&1 <<'SQL'
BEGIN;
  INSERT INTO it_stack_lab (module, lab_number, status) VALUES ('rollbacktest','00-98','shouldnotexist');
ROLLBACK;
SQL
then
  if ! psql_admin "SELECT 1 FROM it_stack_lab WHERE lab_number='00-98';" \
      | grep -q "1"; then
    pass "ROLLBACK correctly discards changes"
  else
    fail "ROLLBACK failed — row persists after rollback"
  fi
else
  fail "ROLLBACK test could not run"
fi

# 3.9 Encoding and collation
info "3.9 — Encoding and collation"
if psql_admin "SELECT encoding, datcollate FROM pg_database WHERE datname='labdb';" \
    | grep -q "UTF8"; then
  pass "labdb uses UTF8 encoding"
else
  fail "labdb encoding is not UTF8"
fi

# 3.10 appuser privilege isolation (should NOT access testdb)
info "3.10 — Privilege isolation"
if PGPASSWORD="${APP_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" \
    -U "${APP_USER}" -d testdb -c "SELECT 1;" > /dev/null 2>&1; then
  fail "appuser can connect to testdb (expected isolation failure)"
else
  pass "appuser cannot connect to testdb (isolation correct)"
fi

# 3.11 Performance baseline
info "3.11 — Performance baseline"
START_MS=$(date +%s%3N)
psql_admin "SELECT count(*) FROM generate_series(1, 100000);" > /dev/null 2>&1
END_MS=$(date +%s%3N)
ELAPSED=$((END_MS - START_MS))
if [[ "${ELAPSED}" -lt 5000 ]]; then
  pass "generate_series(100000) completed in ${ELAPSED}ms (<5000ms threshold)"
else
  warn "generate_series(100000) took ${ELAPSED}ms (may indicate slow I/O)"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
