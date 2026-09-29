#!/usr/bin/env bash
# READ-ONLY report of the old (non-workout) Health data still on the server. Changes nothing.
source "$(dirname "$0")/lib.sh"
step "install server dependencies"
(cd "$ROOT/firebase/functions" && npm ci --no-audit --no-fund >/dev/null)
step "legacy data (everything except workouts, daily context and raw workout streams)"
cd "$ROOT/firebase/functions"
GCP_PROJECT_ID="$P" npx --yes tsx scripts/legacy-cleanup.ts plan
