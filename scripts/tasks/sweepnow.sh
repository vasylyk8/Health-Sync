#!/usr/bin/env bash
# Runs the "finish stuck deletions" job now instead of waiting for its 15-minute schedule.
source "$(dirname "$0")/lib.sh"
step "scheduler jobs"
gcloud scheduler jobs list --location="$REGION" --format='table(name.basename(),schedule,state,lastAttemptTime)' 2>&1 | head -20
JOB=$(gcloud scheduler jobs list --location="$REGION" --format='value(name.basename())' 2>/dev/null | grep -i 'sweepStuckDeletions' | head -1)
[[ -n "$JOB" ]] || fail "sweepStuckDeletions scheduler job not found (has the deploy finished?)"
step "run $JOB"
gcloud scheduler jobs run "$JOB" --location="$REGION"
sleep 60
"$(dirname "$0")/purgediag.sh"
