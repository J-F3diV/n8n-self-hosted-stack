#!/usr/bin/env bash
# Create .env from .env.example and generate strong secrets.
# Usage: ./scripts/init-env.sh [domain]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  echo ".env already exists — not touching it." >&2
  exit 1
fi

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

domain="${1:-}"
umask 077

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    POSTGRES_PASSWORD=__GENERATE__) echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)" ;;
    N8N_ENCRYPTION_KEY=__GENERATE__) echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" ;;
    DOMAIN=*) if [[ -n "$domain" ]]; then echo "DOMAIN=$domain"; else echo "$line"; fi ;;
    *) echo "$line" ;;
  esac
done < .env.example > .env

echo "Created .env (mode 600)."
echo "Next: review DOMAIN, then copy N8N_ENCRYPTION_KEY to your password manager."
