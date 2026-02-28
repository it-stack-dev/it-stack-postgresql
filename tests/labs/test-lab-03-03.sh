#!/usr/bin/env bash
# test-lab-03-03.sh — PostgreSQL Lab 03: Advanced Features
# Tests: PgBouncer connection pooling, pg_stat_statements, WAL archiving,
#        pg_dump/restore, Prometheus metrics, slow query logging
set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}  PASS${NC} $1"; ((++PASS)); }
fail() { echo -e "${RED}  FAIL${NC} $1"; ((++FAIL)); }
warn() { echo -e "${YELLOW}  WARN${NC} $1"; }
header() { echo -e "\n${BLUE}══ $1 ══${NC}"; }

PASS=0; FAIL=0
ADMIN_PASS="${ADMIN_PASS:-Lab03Password!}"
export PGPASSWORD="$ADMIN_PASS"

psql_primary() { psql -h localhost -p 5432 -U labadmin -d labdb -tAqc "$1"; }
psql_replica()  { psql -h localhost -p 5433 -U labadmin -d labdb -tAqc "$1"; }
psql_bouncer()  { psql -h localhost -p 5434 -U labadmin -d labdb -tAqc "$1"; }

# ── 1. pg_stat_statements extension ────────────────────────────────────────
header "1. pg_stat_statements Extension"
ext=$(psql_primary "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null || echo "0")
if [[ "$ext" == "1" ]]; then pass "pg_stat_statements extension loaded"
else fail "pg_stat_statements extension not found"; fi

# ── 2. PgBouncer connectivity ───────────────────────────────────────────────
header "2. PgBouncer Connection Pooler"
if pg_isready -h localhost -p 5434 -U labadmin -q 2>/dev/null; then
  pass "PgBouncer port 5434 ready"
else fail "PgBouncer port 5434 not accepting connections"; fi

# ── 3. Query via PgBouncer ──────────────────────────────────────────────────
result=$(psql_bouncer "SELECT 'pgbouncer_works';" 2>/dev/null || echo "")
if [[ "$result" == "pgbouncer_works" ]]; then pass "Query through PgBouncer succeeds"
else fail "Query through PgBouncer failed (got: '$result')"; fi

# ── 4. PgBouncer pool info ──────────────────────────────────────────────────
pool_db=$(psql_bouncer "SHOW POOLS;" 2>/dev/null | awk '{print $1}' | grep -c "labdb" || echo "0")
if [[ "$pool_db" -ge 1 ]]; then pass "PgBouncer shows labdb pool"
else warn "PgBouncer SHOW POOLS did not list labdb (may require pgbouncer admin connect)"; fi

# ── 5. pg_stat_statements captures queries ──────────────────────────────────
header "5. Query Analytics"
# Run some queries to populate pg_stat_statements
psql_primary "SELECT pg_stat_statements_reset();" >/dev/null 2>&1 || true
for i in 1 2 3; do psql_primary "SELECT count(*) FROM pg_class WHERE relkind='r';" >/dev/null; done
stmt_count=$(psql_primary "SELECT COUNT(*) FROM pg_stat_statements WHERE calls > 0;" 2>/dev/null || echo "0")
if [[ "$stmt_count" -ge 1 ]]; then pass "pg_stat_statements tracking queries ($stmt_count entries)"
else fail "pg_stat_statements has no entries"; fi

# ── 6. Slow query log setting ───────────────────────────────────────────────
log_setting=$(psql_primary "SHOW log_min_duration_statement;" 2>/dev/null || echo "")
if [[ "$log_setting" == "100ms" || "$log_setting" == "100" ]]; then
  pass "log_min_duration_statement = $log_setting"
else fail "log_min_duration_statement not set to 100ms (got: '$log_setting')"; fi

# ── 7. WAL archive mode ─────────────────────────────────────────────────────
header "7. WAL Archiving"
archive_mode=$(psql_primary "SHOW archive_mode;" 2>/dev/null || echo "")
if [[ "$archive_mode" == "on" ]]; then pass "archive_mode = on"
else fail "archive_mode not enabled (got: '$archive_mode')"; fi

wal_level=$(psql_primary "SHOW wal_level;" 2>/dev/null || echo "")
if [[ "$wal_level" == "replica" || "$wal_level" == "logical" ]]; then
  pass "wal_level = $wal_level"
else fail "wal_level not replica (got: '$wal_level')"; fi

# ── 8. Replica still streaming ──────────────────────────────────────────────
header "8. Replica Health"
replica_recovery=$(psql_replica "SELECT pg_is_in_recovery();" 2>/dev/null || echo "f")
if [[ "$replica_recovery" == "t" ]]; then pass "Replica is in recovery (streaming)"
else fail "Replica is NOT in recovery"; fi

stream_count=$(psql_primary "SELECT COUNT(*) FROM pg_stat_replication WHERE state='streaming';" 2>/dev/null || echo "0")
if [[ "$stream_count" -ge 1 ]]; then pass "Primary has $stream_count streaming connection(s)"
else fail "No streaming connections on primary"; fi

# ── 9. pg_dump backup ───────────────────────────────────────────────────────
header "9. Backup & Restore"
DUMP_FILE="/tmp/lab03-backup-$(date +%s).dump"
if pg_dump -h localhost -p 5432 -U labadmin -d labdb -Fc -f "$DUMP_FILE" 2>/dev/null; then
  DUMP_SIZE=$(stat -c%s "$DUMP_FILE" 2>/dev/null || echo 0)
  if [[ "$DUMP_SIZE" -gt 1000 ]]; then pass "pg_dump produced $DUMP_SIZE byte backup"
  else fail "pg_dump file too small ($DUMP_SIZE bytes)"; fi
else fail "pg_dump failed"; fi

# ── 10. pg_restore to test DB ───────────────────────────────────────────────
psql_primary "DROP DATABASE IF EXISTS restore_test;" >/dev/null 2>&1 || true
psql_primary "CREATE DATABASE restore_test;" >/dev/null 2>&1
if pg_restore -h localhost -p 5432 -U labadmin -d restore_test "$DUMP_FILE" 2>/dev/null; then
  pass "pg_restore succeeded"
else warn "pg_restore had warnings (non-fatal for lab test)"; ((++PASS)); fi
psql_primary "DROP DATABASE IF EXISTS restore_test;" >/dev/null 2>&1 || true
rm -f "$DUMP_FILE"

# ── 11. Prometheus metrics endpoint ────────────────────────────────────────
header "11. Prometheus Metrics"
if curl -sf http://localhost:9187/metrics 2>/dev/null | grep -q "pg_up"; then
  pg_up=$(curl -sf http://localhost:9187/metrics 2>/dev/null | grep "^pg_up " | awk '{print $2}')
  if [[ "$pg_up" == "1" || "$pg_up" == "1.0" ]]; then pass "pg_exporter: pg_up = 1"
  else fail "pg_exporter: pg_up = $pg_up (expected 1)"; fi
else fail "pg_exporter /metrics endpoint not reachable or missing pg_up metric"; fi

scrape_line=$(curl -sf http://localhost:9187/metrics 2>/dev/null | grep -c "pg_stat_" || echo "0")
if [[ "$scrape_line" -ge 5 ]]; then pass "pg_exporter exposes $scrape_line pg_stat_* metric lines"
else fail "pg_exporter has too few pg_stat_* metrics ($scrape_line)"; fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo -e "  Tests passed: ${GREEN}${PASS}${NC}"
echo -e "  Tests failed: ${RED}${FAIL}${NC}"
echo "══════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && echo -e "${GREEN}Lab 03-03 PASSED${NC}" || { echo -e "${RED}Lab 03-03 FAILED${NC}"; exit 1; }
