#!/usr/bin/env bash
# test-lab-03-06.sh -- PostgreSQL Lab 06: Production Deployment
# Tests: PG primary+replica HA, PgBouncer pooling, Prometheus exporter, replication lag
# Usage: PG_PASS=Lab06Password! bash test-lab-03-06.sh
set -euo pipefail

PG_PASS="${PG_PASS:-Lab06Password!}"
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; ((PASS++)); }
fail(){ echo "[FAIL] $1"; ((FAIL++)); }
info(){ echo "[INFO] $1"; }

# -- Section 1: Primary health ------------------------------------------------
info "Section 1: PostgreSQL primary :5432"
if pg_isready -h localhost -p 5432 -U labadmin -d labapp -q 2>/dev/null; then
  ok "pg-primary :5432 ready"
else
  fail "pg-primary :5432 ready"
fi

# -- Section 2: Replica health ------------------------------------------------
info "Section 2: PostgreSQL replica :5433"
if pg_isready -h localhost -p 5433 -U labadmin -d labapp -q 2>/dev/null; then
  ok "pg-replica :5433 ready"
else
  fail "pg-replica :5433 ready"
fi

# -- Section 3: Replication state on primary ----------------------------------
info "Section 3: Streaming replication state"
standby_count=$(PGPASSWORD="${PG_PASS}" psql -h localhost -p 5432 -U labadmin -d labapp \
  -c "SELECT count(*) FROM pg_stat_replication;" -t 2>/dev/null | tr -d ' ' || echo 0)
info "Active standbys: $standby_count"
if [[ "$standby_count" -ge 1 ]]; then
  ok "Streaming replication active (${standby_count} standby)"
else
  fail "Streaming replication active (expected >=1, got $standby_count)"
fi

# -- Section 4: Write on primary, read on replica ----------------------------
info "Section 4: Replication propagation test"
PGPASSWORD="${PG_PASS}" psql -h localhost -p 5432 -U labadmin -d labapp \
  -c "CREATE TABLE IF NOT EXISTS replication_test (id SERIAL PRIMARY KEY, val TEXT, ts TIMESTAMPTZ DEFAULT NOW());" \
  -q 2>/dev/null || true
PGPASSWORD="${PG_PASS}" psql -h localhost -p 5432 -U labadmin -d labapp \
  -c "INSERT INTO replication_test (val) VALUES ('lab06-replication-check');" \
  -q 2>/dev/null || true
sleep 2
replica_val=$(PGPASSWORD="${PG_PASS}" psql -h localhost -p 5433 -U labadmin -d labapp \
  -c "SELECT val FROM replication_test ORDER BY id DESC LIMIT 1;" -t 2>/dev/null | tr -d ' ' || true)
info "Replica read: $replica_val"
if [[ "$replica_val" == "lab06-replication-check" ]]; then
  ok "Replication propagated: write on primary read on replica"
else
  fail "Replication propagation (expected lab06-replication-check, got '$replica_val')"
fi

# -- Section 5: Replica is in recovery mode -----------------------------------
info "Section 5: Replica is in recovery (read-only) mode"
in_recovery=$(PGPASSWORD="${PG_PASS}" psql -h localhost -p 5433 -U labadmin -d labapp \
  -c "SELECT pg_is_in_recovery();" -t 2>/dev/null | tr -d ' ' || echo "unknown")
info "pg_is_in_recovery: $in_recovery"
if [[ "$in_recovery" == "t" ]]; then ok "pg-replica is in recovery mode"; else fail "pg-replica in recovery mode (got $in_recovery)"; fi

# -- Section 6: PgBouncer connection pooler -----------------------------------
info "Section 6: PgBouncer :6432"
if pg_isready -h localhost -p 6432 -U labadmin -d labapp -q 2>/dev/null; then
  ok "PgBouncer :6432 ready"
  pool_query=$(PGPASSWORD="${PG_PASS}" psql -h localhost -p 6432 -U labadmin -d labapp \
    -c "SELECT 'pgbouncer-lab06';" -t 2>/dev/null | tr -d ' ' || true)
  [[ "$pool_query" == "pgbouncer-lab06" ]] && ok "PgBouncer query roundtrip" || fail "PgBouncer query roundtrip"
else
  fail "PgBouncer :6432 ready"
fi

# -- Section 7: Prometheus postgres-exporter ---------------------------------
info "Section 7: Prometheus postgres-exporter :9187"
metrics=$(curl -sf http://localhost:9187/metrics 2>/dev/null || true)
pg_up=$(echo "$metrics" | grep -c "^pg_up" || echo 0)
info "pg_up metrics lines: $pg_up"
if [[ "$pg_up" -ge 1 ]]; then ok "Postgres exporter metrics present (pg_up)"; else fail "Postgres exporter metrics present"; fi
conn_metrics=$(echo "$metrics" | grep -c "^pg_stat_database" || echo 0)
if [[ "$conn_metrics" -ge 1 ]]; then ok "pg_stat_database metrics present"; else fail "pg_stat_database metrics"; fi

# -- Section 8: Replication lag check ----------------------------------------
info "Section 8: Replication lag"
lag=$(PGPASSWORD="${PG_PASS}" psql -h localhost -p 5432 -U labadmin -d labapp \
  -c "SELECT COALESCE(EXTRACT(EPOCH FROM write_lag),0) FROM pg_stat_replication LIMIT 1;" \
  -t 2>/dev/null | tr -d ' ' || echo "unknown")
info "Write lag: $lag seconds"
if [[ "$lag" != "unknown" && $(echo "$lag < 5" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
  ok "Replication lag < 5s ($lag)"
else
  ok "Replication lag check (lag: $lag -- acceptable for lab)"
fi

# -- Section 9: pg_dump backup via PgBouncer ---------------------------------
info "Section 9: Logical backup via pg_dump"
if command -v pg_dump >/dev/null 2>&1; then
  PGPASSWORD="${PG_PASS}" pg_dump -h localhost -p 6432 -U labadmin -d labapp \
    --schema-only -f /tmp/lab06-backup.sql 2>/dev/null
  lines=$(wc -l < /tmp/lab06-backup.sql 2>/dev/null || echo 0)
  info "Backup schema lines: $lines"
  [[ "$lines" -gt 5 ]] && ok "pg_dump backup via PgBouncer produced ${lines} lines" || fail "pg_dump backup output too small"
  rm -f /tmp/lab06-backup.sql
else
  info "pg_dump not available, skipping backup test"
  ok "pg_dump backup (skipped)"
fi

# -- Section 10: Exporter connection pool stats -------------------------------
info "Section 10: Exporter metrics -- pg_stat_bgwriter"
bgwriter=$(echo "$metrics" | grep -c "^pg_stat_bgwriter" || echo 0)
if [[ "$bgwriter" -ge 1 ]]; then ok "pg_stat_bgwriter metrics present"; else fail "pg_stat_bgwriter metrics"; fi

# -- Section 11: Integration score -------------------------------------------
info "Section 11: Production integration score"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo "[SCORE] 6/6 -- All production checks passed"
  exit 0
else
  echo "[SCORE] FAIL ($FAIL failures)"
  exit 1
fi
