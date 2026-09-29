#!/usr/bin/env bash
# IRREVERSIBLE: deletes the old non-workout Health data from the server with NO backup (owner's choice;
# Apple Health on the phone remains the original).
# Workouts, daily context, raw workout streams, links and the account are never touched.
# Run cleanup-legacy-plan first, and only after the new server and app are deployed.
source "$(dirname "$0")/lib.sh"
step "install server dependencies"
(cd "$ROOT/firebase/functions" && npm ci --no-audit --no-fund >/dev/null)
step "delete and verify (no backup, by the owner's choice)"
cd "$ROOT/firebase/functions"
node scripts/copy-shared.mjs
SKIP_BACKUP=1 GCP_PROJECT_ID="$P" npx --yes tsx scripts/legacy-cleanup.ts run
