#!/usr/bin/env bash
# Read-only diagnostics for the ingestion pipeline (logs, trigger, bucket contents).
source "$(dirname "$0")/lib.sh"
step "ingest trigger"
gcloud eventarc triggers list --location="$REGION" --format='table(name,destination.cloudRun.service,eventFilters)' || true
gcloud functions describe ingest --region="$REGION" --format='yaml(state,eventTrigger,serviceConfig.serviceAccountEmail)' || true
step "incoming objects"
gcloud storage ls -l "gs://$INCOMING/incoming/**" 2>&1 | tail -12 || true
step "data objects"
gcloud storage ls "gs://$DATA/**" 2>&1 | head -12 || true
step "ingest logs (last 2h)"
gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"ingest\" AND severity>=DEFAULT" \
  --freshness=2h --limit=60 --format='value(timestamp,severity,textPayload,jsonPayload.message,jsonPayload.code,jsonPayload.err,httpRequest.status)' || true
step "eventarc/pubsub delivery errors"
gcloud logging read "(resource.type=\"eventarc.googleapis.com/Trigger\" OR resource.type=\"pubsub_subscription\") AND severity>=WARNING" --freshness=2h --limit=20 --format='value(timestamp,severity,textPayload,jsonPayload)' || true
step "uptime check results (last 30 min)"
START=$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ); END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
api GET "https://monitoring.googleapis.com/v3/projects/$P/timeSeries?filter=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\""))')&interval.startTime=$START&interval.endTime=$END" |
  python3 -c '
import json, sys, collections
d = json.load(sys.stdin)
res = collections.defaultdict(lambda: [0, 0])
for ts in d.get("timeSeries", []):
    cid = ts["metric"]["labels"].get("check_id", "?")
    for p in ts.get("points", []):
        res[cid][0 if p["value"].get("boolValue") else 1] += 1
for cid, (ok, bad) in sorted(res.items()):
    print(f"{cid}: {ok} passed, {bad} failed")
if not res: print("no uptime results yet", json.dumps(d)[:300])
'
