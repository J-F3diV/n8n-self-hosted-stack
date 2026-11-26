#!/usr/bin/env bash
# End-to-end smoke test of the whole stack on localhost.
# Boots Caddy + n8n + PostgreSQL, checks HTTPS and metrics exposure,
# the stuck-execution monitor, and a backup -> restore round trip.
# Used in CI; safe to run locally on a machine without anything on ports 80/443.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f .env ]] || ./scripts/init-env.sh localhost
# shellcheck disable=SC1091
set -a; . ./.env; set +a
[[ "$DOMAIN" == "localhost" ]] || fail "smoke test expects DOMAIN=localhost"

step "Starting stack"
docker compose up -d --wait --wait-timeout 300

step "HTTPS through Caddy"
code="$(curl -sk -o /dev/null -w '%{http_code}' --retry 10 --retry-delay 3 --retry-all-errors https://localhost/healthz)"
[[ "$code" == "200" ]] || fail "/healthz returned $code"
curl -sk https://localhost/ | grep -qi '<html' || fail "editor UI not served"

step "Metrics are not public"
code="$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/metrics)"
[[ "$code" == "404" ]] || fail "/metrics returned $code, expected 404"

step "Monitor: healthy stack"
./scripts/check-stuck-executions.sh 1 || fail "monitor reported problems on a fresh stack"

step "Monitor: detects a stuck execution"
# Synthetic row; FK triggers are bypassed so no workflow has to exist.
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
SET session_replication_role = replica;
INSERT INTO execution_entity (finished, mode, status, "createdAt", "startedAt", "workflowId")
VALUES (false, 'trigger', 'running', now() - interval '3 hours', now() - interval '3 hours', 'smoke-test');
SQL
set +e
out="$(./scripts/check-stuck-executions.sh 60)"
rc=$?
set -e
echo "$out"
[[ $rc -eq 2 ]] || fail "monitor exit code $rc, expected 2"
grep -q 'smoke-test' <<< "$out" || fail "monitor output does not list the stuck execution"

step "Backup"
db_dump="$(./scripts/backup.sh)"
[[ -s "$db_dump" ]] || fail "empty backup"
ls -l "${BACKUP_DIR:-./backups}"

step "Restore round trip"
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "DELETE FROM execution_entity WHERE \"workflowId\" = 'smoke-test';"
data_tar="${db_dump/n8n-db-/n8n-data-}"
data_tar="${data_tar%.dump}.tar.gz"
./scripts/restore.sh --yes "$db_dump" "$data_tar"
restored="$(docker compose exec -T postgres psql -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT count(*) FROM execution_entity WHERE \"workflowId\" = 'smoke-test';")"
[[ "$restored" == "1" ]] || fail "restored row count is '$restored', expected 1"
code="$(curl -sk -o /dev/null -w '%{http_code}' --retry 10 --retry-delay 3 --retry-all-errors https://localhost/healthz)"
[[ "$code" == "200" ]] || fail "n8n unhealthy after restore ($code)"

printf '\nAll smoke tests passed.\n'
