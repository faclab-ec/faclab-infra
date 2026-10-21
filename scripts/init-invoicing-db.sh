#!/usr/bin/env bash
# faclab-invoicing's role and databases: faclab_invoicing (the service) and faclab_invoicing_test
# (its PostgreSQL tests), both owned by the faclab_invoicing role.
#
# The postgres image runs it once, when the volume is empty. It is idempotent: to apply it to an
# existing volume (or after changing INVOICING_DB_PASSWORD):
#
#   docker compose exec invoicing-db /docker-entrypoint-initdb.d/init-invoicing-db.sh
set -euo pipefail

ROLE="faclab_invoicing"
DATABASES=(faclab_invoicing faclab_invoicing_test)
PASSWORD="${INVOICING_DB_PASSWORD:?INVOICING_DB_PASSWORD is required}"

psql_admin() {
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname postgres --quiet "$@"
}

echo "Creating role '$ROLE' if it doesn't exist..."
psql_admin -v role="$ROLE" -v password="$PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'role', :'password')\gexec
SQL

for database in "${DATABASES[@]}"; do
  echo "Creating database '$database' if it doesn't exist..."
  psql_admin -v database="$database" -v role="$ROLE" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'database', :'role')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'database')\gexec
SQL
done

echo "faclab-invoicing databases ready."
