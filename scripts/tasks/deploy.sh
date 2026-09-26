#!/usr/bin/env bash
# Provision (idempotent) → deploy server → seed synthetic user → live smoke test → monitoring.
source "$(dirname "$0")/lib.sh"

"$ROOT/scripts/tasks/provision.sh"

step "Build and deploy"
cd "$ROOT/firebase/functions"
npm ci --no-audit --no-fund
cat > .env.$P <<ENV
INCOMING_BUCKET=$INCOMING
DATA_BUCKET=$DATA
PUBLIC_BASE_URL=$BASE_URL
RUNTIME_SA=${GCP_RUNTIME_SA:?GCP_RUNTIME_SA secret missing}
ENFORCE_APP_CHECK=${ENFORCE_APP_CHECK:-false}
ENV
cd "$ROOT/firebase"
firebase_cli target:apply storage incoming "$INCOMING" >/dev/null
firebase_cli deploy --only functions,firestore,storage,hosting --force

step "Synthetic monitoring user"
if ! gcloud secrets describe synthetic-mcp-token >/dev/null 2>&1; then
  python3 -c "import secrets; print(secrets.token_urlsafe(32)[:43], end='')" | gcloud secrets create synthetic-mcp-token --data-file=- --replication-policy=user-managed --locations="$REGION" >/dev/null
fi
SYNTHETIC_TOKEN=$(gcloud secrets versions access latest --secret=synthetic-mcp-token)
export SYNTHETIC_TOKEN GCP_PROJECT_ID
(cd "$ROOT/firebase/functions" && node "$ROOT/scripts/synthetic/seed.mjs")

step "Live smoke test"
"$ROOT/scripts/tasks/smoke.sh"

step "Monitoring"
"$ROOT/scripts/tasks/monitoring.sh"
echo; echo "Deployed: $BASE_URL"
