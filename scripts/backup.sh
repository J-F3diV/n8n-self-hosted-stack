#!/usr/bin/env bash
# Back up the n8n database and data directory while the stack is running.
# Produces: n8n-db-<ts>.dump, n8n-data-<ts>.tar.gz and a SHA256SUMS file.
# Usage: ./scripts/backup.sh
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

backup_dir="${BACKUP_DIR:-./backups}"
retention="${BACKUP_RETENTION_DAYS:-14}"
[[ "$retention" =~ ^[0-9]+$ ]] || { echo "BACKUP_RETENTION_DAYS must be an integer" >&2; exit 1; }

mkdir -p "$backup_dir"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
db_file="$backup_dir/n8n-db-$ts.dump"
data_file="$backup_dir/n8n-data-$ts.tar.gz"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

log "Dumping PostgreSQL database '$POSTGRES_DB'"
compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$work/db.dump"

log "Verifying dump"
compose exec -T postgres pg_restore --list < "$work/db.dump" > /dev/null

log "Copying n8n data directory"
compose cp n8n:/home/node/.n8n "$work/n8n-data" > /dev/null
tar -C "$work" -czf "$work/data.tar.gz" n8n-data

mv "$work/db.dump" "$db_file"
mv "$work/data.tar.gz" "$data_file"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
( cd "$backup_dir" && sha256 "$(basename "$db_file")" "$(basename "$data_file")" > "n8n-$ts.SHA256SUMS" )

log "Removing backups older than $retention days"
find "$backup_dir" -maxdepth 1 -type f -name 'n8n-*' -mtime +"$retention" -print -delete >&2

log "Done: $db_file, $data_file"
echo "$db_file"
