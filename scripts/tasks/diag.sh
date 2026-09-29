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
