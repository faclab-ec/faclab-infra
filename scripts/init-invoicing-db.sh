#!/usr/bin/env bash
# faclab-invoicing's role and databases: faclab_invoicing (the service) and faclab_invoicing_test
# (its PostgreSQL tests), both owned by the faclab_invoicing role; INVOICING_DATABASES changes the
# list (production: only faclab_invoicing). With MONITOR_DB_PASSWORD it also creates faclab_monitor,
# the OTel Collector's user (S7.4): pg_monitor reads statistics, never rows.
#
# The postgres image runs it once, when the volume is empty. It is idempotent: to apply it to an
# existing volume (or after changing INVOICING_DB_PASSWORD):
#
#   docker compose exec invoicing-db /docker-entrypoint-initdb.d/init-invoicing-db.sh
#
# deploy/production/scripts/stack.sh runs it on every migrate, against the shared PostgreSQL.
set -euo pipefail

ROLE="faclab_invoicing"
read -r -a DATABASES <<< "${INVOICING_DATABASES:-faclab_invoicing faclab_invoicing_test}"
PASSWORD="${INVOICING_DB_PASSWORD:?INVOICING_DB_PASSWORD is required}"
MONITOR_ROLE="faclab_monitor"
MONITOR_PASSWORD="${MONITOR_DB_PASSWORD:-}"

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

if [[ -n "$MONITOR_PASSWORD" ]]; then
  echo "Creating role '$MONITOR_ROLE' (pg_monitor) if it doesn't exist..."
  psql_admin -v role="$MONITOR_ROLE" -v password="$MONITOR_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')\gexec
SELECT format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L',
              :'role', :'password')\gexec
SELECT format('GRANT pg_monitor TO %I', :'role')\gexec
SQL
else
  echo "MONITOR_DB_PASSWORD is empty: skipping '$MONITOR_ROLE'."
fi

echo "faclab-invoicing databases ready."
