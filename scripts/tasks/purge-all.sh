#!/usr/bin/env bash
# IRREVERSIBLE in "run" mode: deletes every real account and its data. The synthetic monitoring user and the
# directory reviewer account are kept. "plan" is read-only.
#   scripts/tasks/purge-all.sh plan|run
source "$(dirname "$0")/lib.sh"
MODE="${1:-plan}"
[[ "$MODE" == "plan" || "$MODE" == "run" ]] || fail "usage: purge-all.sh plan|run"
step "install server dependencies"
(cd "$ROOT/firebase/functions" && npm ci --no-audit --no-fund >/dev/null)
step "purge-all $MODE"
cd "$ROOT/firebase/functions"
GCP_PROJECT_ID="$P" npx --yes tsx scripts/purge-all.ts "$MODE"
