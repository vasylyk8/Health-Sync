#!/usr/bin/env bash
# Read-only diagnostics for account deletion: which accounts are mid-deletion, and whether the purge job is running.
# Prints account status flags and queue state only, never health data.
source "$(dirname "$0")/lib.sh"

step "accounts marked as deleting (status only)"
api POST "https://firestore.googleapis.com/v1/projects/$P/databases/(default)/documents:runQuery" \
  '{"structuredQuery":{"from":[{"collectionId":"users"}],"where":{"fieldFilter":{"field":{"fieldPath":"deleting"},"op":"EQUAL","value":{"booleanValue":true}}},"select":{"fields":[{"fieldPath":"createdAt"},{"fieldPath":"generation"}]},"limit":20}}' |
  python3 -c '
import json, sys, datetime
d = json.load(sys.stdin)
rows = [r["document"] for r in d if isinstance(r, dict) and "document" in r]
print(f"{len(rows)} account(s) currently marked deleting")
for doc in rows:
    f = doc.get("fields", {})
    created = f.get("createdAt", {}).get("integerValue")
    when = datetime.datetime.utcfromtimestamp(int(created) / 1000).isoformat() + "Z" if created else "?"
    print(" -", doc["name"].split("/")[-1][:8] + "…", "created", when, "generation", f.get("generation", {}).get("integerValue", "?"))
if not rows: print(json.dumps(d)[:400])
' || true

step "purge queue"
gcloud tasks queues describe purgeusertask --location="$REGION" --format='yaml(state,rateLimits,retryConfig)' 2>&1 | head -20 || true
gcloud tasks list --queue=purgeusertask --location="$REGION" --format='table(name.basename(),scheduleTime,dispatchCount,responseCount,lastAttempt.responseStatus.code)' 2>&1 | head -20 || true

step "purge task logs (last 6h)"
gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"purgeusertask\"" \
  --freshness=6h --limit=40 --format='value(timestamp,severity,textPayload,jsonPayload.message,jsonPayload.code,jsonPayload.err)' 2>&1 | head -60 || true
