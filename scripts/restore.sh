#!/usr/bin/env bash
# Restore the n8n database (and optionally the data directory) from a backup.
# DESTRUCTIVE: replaces the current database.
# Usage: ./scripts/restore.sh --yes backups/n8n-db-<ts>.dump [backups/n8n-data-<ts>.tar.gz]
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

if [[ "${1:-}" != "--yes" || -z "${2:-}" ]]; then
  echo "Usage: $0 --yes <db.dump> [data.tar.gz]" >&2
  echo "This replaces the current n8n database. Pass --yes to confirm." >&2
  exit 1
fi
db_file="$2"
data_file="${3:-}"
[[ -f "$db_file" ]] || { echo "Not found: $db_file" >&2; exit 1; }
[[ -z "$data_file" || -f "$data_file" ]] || { echo "Not found: $data_file" >&2; exit 1; }

log "Checking dump"
compose exec -T postgres pg_restore --list < "$db_file" > /dev/null

log "Stopping n8n"
compose stop n8n

log "Recreating database '$POSTGRES_DB'"
compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);" \
  -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";"

log "Restoring dump"
compose exec -T postgres pg_restore --no-owner --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$db_file"

if [[ -n "$data_file" ]]; then
  log "Restoring n8n data directory"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  tar -C "$work" -xzf "$data_file"
  compose cp "$work/n8n-data/." n8n:/home/node/.n8n > /dev/null
  compose run --rm --no-deps --user root --entrypoint chown n8n -R node:node /home/node/.n8n
fi

log "Starting n8n"
compose up -d --wait n8n
log "Restore complete"
