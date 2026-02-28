#!/bin/bash
set -e
# Create Keycloak database + user
psql -v ON_ERROR_STOP=1 --username=postgres <<-EOSQL
    CREATE USER keycloak WITH PASSWORD 'Lab05Password!';
    CREATE DATABASE keycloak OWNER keycloak;
    GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;

    CREATE USER labapp WITH PASSWORD 'Lab05Password!';
    CREATE DATABASE labapp OWNER labapp;
    GRANT ALL PRIVILEGES ON DATABASE labapp TO labapp;
EOSQL