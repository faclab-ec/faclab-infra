# syntax=docker/dockerfile:1

# PostgreSQL of Faclab (S8.3): the official image plus pgBackRest, which archives the WAL from
# archive_command and takes the backups (deploy/production/RESPALDOS.md), and curl, which
# scripts/backups.sh uses to send the backup metrics to the Collector. pgBackRest comes from the
# PGDG repository the official image already configures, pinned to a version; the same major and
# Debian release as the official image, so the data directory stays compatible
ARG POSTGRES_VERSION=17.12

FROM postgres:${POSTGRES_VERSION}

ARG PGBACKREST_VERSION=2.60.1-1.pgdg13+1

# The upgrade brings the security fixes the official image doesn't have yet: the image scan fails
# on a HIGH or CRITICAL with a fix (S9.3)
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}" curl \
    && rm -rf /var/lib/apt/lists/* \
    # The spool (asynchronous archiving), its lock and its log, owned by postgres: archive_command
    # and the backups run as that user
    && install -d -o postgres -g postgres -m 0750 /var/spool/pgbackrest /var/log/pgbackrest /tmp/pgbackrest

# The configuration is mounted by the compose file (/etc/pgbackrest/pgbackrest.conf); the repository,
# its keys and the passphrase come as PGBACKREST_* variables
