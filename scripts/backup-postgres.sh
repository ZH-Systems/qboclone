#!/bin/sh
# Run with DATABASE_URL from your secret manager. Never commit database credentials.
set -eu
: "${DATABASE_URL:?Set DATABASE_URL to the PostgreSQL connection string}"
command -v pg_dump >/dev/null 2>&1 || { echo "pg_dump is required" >&2; exit 1; }
command -v pg_restore >/dev/null 2>&1 || { echo "pg_restore is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }
BACKUP_DIR=${BACKUP_DIR:-"./backups"}
mkdir -p "$BACKUP_DIR"
umask 077
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
target="$BACKUP_DIR/qboclone-$timestamp.dump"
partial="$target.partial"
trap 'rm -f "$partial"' EXIT HUP INT TERM
# libpq accepts a connection URI in PGDATABASE. Avoid logging credentials as arguments.
PGDATABASE="$DATABASE_URL" pg_dump --format=custom --no-owner --no-acl --file="$partial"
pg_restore --list "$partial" >/dev/null
mv "$partial" "$target"
(
  cd "$BACKUP_DIR"
  sha256sum "$(basename "$target")" > "$(basename "$target").sha256"
)
echo "Database archive completed: $target"
echo "Store this archive off-host in encrypted, access-controlled storage."
