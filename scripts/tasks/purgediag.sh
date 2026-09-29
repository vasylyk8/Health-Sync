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

step "task queues in this region"
gcloud tasks queues list --location="$REGION" --format='table(name.basename(),state)' 2>&1 | head -20 || true
for Q in $(gcloud tasks queues list --location="$REGION" --format='value(name.basename())' 2>/dev/null | grep -i purge); do
  step "queue $Q"
  gcloud tasks list --queue="$Q" --location="$REGION" --format='table(name.basename(),scheduleTime,dispatchCount,responseCount,lastAttempt.responseStatus.message)' 2>&1 | head -20 || true
done

step "deleteAllData / purge logs (last 24h, warnings and errors)"
for SVC in deletealldata purgeusertask; do
  echo "--- $SVC"
  gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SVC\" AND severity>=WARNING" \
    --freshness=24h --limit=15 --format='value(timestamp,severity,textPayload,jsonPayload.message,jsonPayload.code,jsonPayload.err)' 2>&1 | head -40 || true
done
step "deleteAllData calls (last 24h)"
gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"deletealldata\" AND textPayload:\"deletion\"" \
  --freshness=24h --limit=10 --format='value(timestamp,textPayload,jsonPayload.message)' 2>&1 | head -20 || true
