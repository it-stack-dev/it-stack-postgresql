#!/usr/bin/env bash
# Creates the pgbouncer monitoring user so PgBouncer can connect for SHOW POOLS
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
  -- pgbouncer auth user (stats only)
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_auth') THEN
      CREATE ROLE pgbouncer_auth WITH LOGIN PASSWORD 'Lab03Password!' NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
  END$$;

  -- Enable pg_stat_statements extension
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

  -- Performance analysis view
  GRANT SELECT ON pg_stat_statements TO labadmin;
EOSQL

echo "pgBouncer auth user and pg_stat_statements configured."
