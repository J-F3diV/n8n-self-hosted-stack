#!/usr/bin/env bash
# Find n8n executions that stay in "new" or "running" longer than expected
# (e.g. after a crash, OOM kill or restart) and check container health.
#
# Exit codes: 0 = healthy, 2 = problems found, 1 = check failed.
# Usage: ./scripts/check-stuck-executions.sh [minutes]
# Optional alert: set ALERT_WEBHOOK_URL (Slack/Discord/Mattermost-compatible).
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

minutes="${1:-${STUCK_AFTER_MINUTES:-60}}"
[[ "$minutes" =~ ^[0-9]+$ ]] || { echo "minutes must be an integer" >&2; exit 1; }

problems=()

# 1. Container health
for svc in postgres n8n; do
  cid="$(compose ps -q "$svc")"
  if [[ -z "$cid" ]]; then
    problems+=("$svc: container not running")
    continue
  fi
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
  [[ "$health" == "healthy" ]] || problems+=("$svc: health=$health")
done

# 2. Executions stuck in new/running
query="SELECT id, \"workflowId\", status,
  to_char(COALESCE(\"startedAt\", \"createdAt\") AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
FROM execution_entity
WHERE \"deletedAt\" IS NULL
  AND status IN ('new', 'running')
  AND COALESCE(\"startedAt\", \"createdAt\") < now() - interval '$minutes minutes'
ORDER BY COALESCE(\"startedAt\", \"createdAt\")
LIMIT 20;"

if ! stuck="$(psql_n8n -At -F ' | ' -c "$query" 2>&1)"; then
  echo "Query failed: $stuck" >&2
  exit 1
fi

if [[ -n "$stuck" ]]; then
  count="$(printf '%s\n' "$stuck" | wc -l | tr -d ' ')"
  problems+=("$count execution(s) in new/running for more than $minutes min (id | workflow | status | since):")
  while IFS= read -r row; do problems+=("  $row"); done <<< "$stuck"
fi

if [[ ${#problems[@]} -eq 0 ]]; then
  log "OK: containers healthy, no executions stuck longer than $minutes min"
  exit 0
fi

report="n8n check on $(hostname) (${DOMAIN}):"
for p in "${problems[@]}"; do report+=$'\n'"$p"; done
echo "$report"

if [[ -n "${ALERT_WEBHOOK_URL:-}" ]]; then
  payload="$(REPORT="$report" python3 -c 'import json,os; t=os.environ["REPORT"]; print(json.dumps({"text": t, "content": t[:1900]}))' 2>/dev/null \
    || printf '{"text":"n8n check found problems on %s"}' "$(hostname)")"
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" "$ALERT_WEBHOOK_URL" > /dev/null \
    || log "WARNING: alert webhook failed"
fi
exit 2
