-- docker/init/01-create-app-users.sql
-- PostgreSQL Lab 01 initialization: create test users and databases
-- Runs automatically on first container start via docker-entrypoint-initdb.d

-- ── App user ────────────────────────────────────────────────────────────────
CREATE USER appuser WITH
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  LOGIN
  ENCRYPTED PASSWORD 'AppPass123!';

-- ── Test user ────────────────────────────────────────────────────────────────
CREATE USER testuser WITH
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  LOGIN
  ENCRYPTED PASSWORD 'TestPass123!';

-- ── Application database ─────────────────────────────────────────────────────
CREATE DATABASE appdb
  WITH OWNER = appuser
  ENCODING = 'UTF8'
  LC_COLLATE = 'C'
  LC_CTYPE = 'C'
  TEMPLATE = template0;

GRANT ALL PRIVILEGES ON DATABASE appdb TO appuser;

-- Revoke PUBLIC create on appdb to match production security posture
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- ── Test database ─────────────────────────────────────────────────────────────
CREATE DATABASE testdb
  WITH OWNER = testuser
  ENCODING = 'UTF8'
  LC_COLLATE = 'C'
  LC_CTYPE = 'C'
  TEMPLATE = template0;

GRANT ALL PRIVILEGES ON DATABASE testdb TO testuser;

-- ── Sample table in labdb (owned by labadmin) ─────────────────────────────────
\connect labdb

CREATE TABLE IF NOT EXISTS it_stack_lab (
  id          SERIAL PRIMARY KEY,
  module      TEXT NOT NULL,
  lab_number  TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO it_stack_lab (module, lab_number, status) VALUES
  ('postgresql', '03-01', 'running'),
  ('redis',      '04-01', 'pending'),
  ('keycloak',   '02-01', 'pending');

GRANT SELECT, INSERT, UPDATE, DELETE ON it_stack_lab TO appuser;
GRANT USAGE, SELECT ON SEQUENCE it_stack_lab_id_seq TO appuser;
