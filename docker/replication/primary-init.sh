#!/bin/bash
# primary-init.sh
# Run once at PostgreSQL primary init via docker-entrypoint-initdb.d
# Creates the replication user used by pg-replica for streaming replication.
set -euo pipefail

echo "==> Creating replicator user for streaming replication..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'replicator') THEN
      CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'Lab02Password!';
      RAISE NOTICE 'Created replicator role';
    ELSE
      RAISE NOTICE 'replicator role already exists';
    END IF;
  END
  \$\$;

  -- Grant pg_monitor to replicator so monitoring tools can authenticate
  GRANT pg_monitor TO replicator;
EOSQL

echo "==> Configuring pg_hba.conf for replication connections..."
# Allow replicator from any host on the pg-net Docker network
cat >> "$PGDATA/pg_hba.conf" <<-EOF
# Streaming replication (added by primary-init.sh)
host  replication  replicator  0.0.0.0/0  scram-sha-256
EOF

echo "==> Replication setup complete."
