#!/usr/bin/env bash
# Rotates the private operator connector without printing either token.
source "$(dirname "$0")/lib.sh"
ANALYTICS_OLD_TOKEN=$(gcloud secrets versions access latest --secret=krok-analytics-mcp-token)
ANALYTICS_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32)[:43], end='')")
export ANALYTICS_OLD_TOKEN ANALYTICS_TOKEN GCP_PROJECT_ID
cd "$ROOT/firebase/functions"
npm ci --no-audit --no-fund >/dev/null
node scripts/rotate-analytics-token.mjs
printf '%s' "$ANALYTICS_TOKEN" | gcloud secrets versions add krok-analytics-mcp-token --data-file=- >/dev/null
unset ANALYTICS_OLD_TOKEN ANALYTICS_TOKEN
echo "Rotation complete. Run scripts/tasks/analytics-link.sh only in a trusted terminal to retrieve the new URL."

