#!/usr/bin/env bash
# Uptime checks + alert policies (idempotent). Alerts go to ALERT_EMAIL.
source "$(dirname "$0")/lib.sh"
CHANNEL=$(cat /tmp/alert-channel 2>/dev/null || gcloud beta monitoring channels list --filter="labels.email_address=\"${ALERT_EMAIL:?}\"" --format='value(name)' | head -1)
TOKEN_RAW=$(gcloud secrets versions access latest --secret=synthetic-mcp-token)

exists_uptime() { gcloud monitoring uptime list-configs --format='value(name,displayName)' | awk -v n="$1" '$2 == n { print $1; exit }'; }
if [[ -z "$(exists_uptime hs-healthz)" ]]; then
  gcloud monitoring uptime create hs-healthz --resource-type=uptime-url --resource-labels=host="$P.web.app",project_id="$P" \
    --path=/health --protocol=https --period=5 --timeout=20 --matcher-content='"ok":true' >/dev/null
fi
if [[ -z "$(exists_uptime hs-mcp-synthetic)" ]]; then
  gcloud monitoring uptime create hs-mcp-synthetic --resource-type=uptime-url --resource-labels=host="$P.web.app",project_id="$P" \
    --path="/mcp/$TOKEN_RAW" --protocol=https --request-method=post --content-type=user-provided --custom-content-type=application/json \
    --headers='^;^Accept=application/json, text/event-stream' \
    --body='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_available_data","arguments":{}}}' \
    --period=5 --timeout=30 --matcher-content='StepCount' >/dev/null
fi

# Log-based metric: server errors (never contains health data; see src/log.ts).
gcloud logging metrics describe hs_errors >/dev/null 2>&1 || gcloud logging metrics create hs_errors \
  --description="Health Sync server errors" --log-filter='resource.type="cloud_run_revision" AND severity>=ERROR'
gcloud logging metrics describe hs_batch_rejected >/dev/null 2>&1 || gcloud logging metrics create hs_batch_rejected \
  --description="Rejected upload batches" --log-filter='resource.type="cloud_run_revision" AND jsonPayload.message="batch rejected"'

policy() { # name json
  if [[ -z "$(gcloud alpha monitoring policies list --filter="displayName=\"$1\"" --format='value(name)' | head -1)" ]]; then
    echo "$2" > /tmp/policy.json
    gcloud alpha monitoring policies create --policy-from-file=/tmp/policy.json >/dev/null
    echo "created alert: $1"
  fi
}
uptime_policy() { # display check
  policy "$1" "{\"displayName\":\"$1\",\"combiner\":\"OR\",\"notificationChannels\":[\"$CHANNEL\"],
    \"conditions\":[{\"displayName\":\"$1\",\"conditionThreshold\":{
      \"filter\":\"metric.type=\\\"monitoring.googleapis.com/uptime_check/check_passed\\\" AND resource.type=\\\"uptime_url\\\" AND metric.label.check_id=\\\"$2\\\"\",
      \"comparison\":\"COMPARISON_GT\",\"thresholdValue\":1,\"duration\":\"600s\",
      \"aggregations\":[{\"alignmentPeriod\":\"300s\",\"perSeriesAligner\":\"ALIGN_NEXT_OLDER\",\"crossSeriesReducer\":\"REDUCE_COUNT_FALSE\",\"groupByFields\":[\"resource.label.project_id\"]}]}}]}"
}
uptime_policy "Health Sync is down" "$(exists_uptime hs-healthz | sed 's#.*/##')"
uptime_policy "AI connector is failing" "$(exists_uptime hs-mcp-synthetic | sed 's#.*/##')"
log_policy() { # display metric threshold
  policy "$1" "{\"displayName\":\"$1\",\"combiner\":\"OR\",\"notificationChannels\":[\"$CHANNEL\"],
    \"conditions\":[{\"displayName\":\"$1\",\"conditionThreshold\":{
      \"filter\":\"metric.type=\\\"logging.googleapis.com/user/$2\\\" AND resource.type=\\\"cloud_run_revision\\\"\",
      \"comparison\":\"COMPARISON_GT\",\"thresholdValue\":$3,\"duration\":\"0s\",
      \"aggregations\":[{\"alignmentPeriod\":\"600s\",\"perSeriesAligner\":\"ALIGN_SUM\",\"crossSeriesReducer\":\"REDUCE_SUM\"}]}}]}"
}
log_policy "Server errors" hs_errors 10
log_policy "Uploads being rejected" hs_batch_rejected 20
echo "Monitoring configured (alerts → ${ALERT_EMAIL})"
