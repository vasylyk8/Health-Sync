#!/usr/bin/env bash
# IRREVERSIBLE (after the backup expires): copies the old non-workout Health data to a private backup
# bucket (auto-deleted after 14 days), verifies every copy, then deletes it from the server.
# Workouts, daily context, raw workout streams, links and the account are never touched.
# Run cleanup-legacy-plan first, and only after the new server and app are deployed.
source "$(dirname "$0")/lib.sh"
BACKUP="$P-legacy-backup"
step "backup bucket gs://$BACKUP (14-day expiry)"
if ! gcloud storage buckets describe "gs://$BACKUP" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$BACKUP" --location="$REGION" --uniform-bucket-level-access --public-access-prevention
fi
LIFECYCLE="$(mktemp)"
echo '{"rule":[{"action":{"type":"Delete"},"condition":{"age":14}}]}' > "$LIFECYCLE"
gcloud storage buckets update "gs://$BACKUP" --lifecycle-file="$LIFECYCLE" --no-soft-delete 2>/dev/null || gcloud storage buckets update "gs://$BACKUP" --lifecycle-file="$LIFECYCLE"
step "install server dependencies"
(cd "$ROOT/firebase/functions" && npm ci --no-audit --no-fund >/dev/null)
step "back up, delete and verify"
cd "$ROOT/firebase/functions"
node scripts/copy-shared.mjs
GCP_PROJECT_ID="$P" npx --yes tsx scripts/legacy-cleanup.ts run
step "done. The backup is kept for 14 days at gs://$BACKUP/legacy/"
