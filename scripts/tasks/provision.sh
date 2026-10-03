#!/usr/bin/env bash
# Idempotent Firebase/Google Cloud setup. Safe to run on every deploy.
source "$(dirname "$0")/lib.sh"

FB="https://firebase.googleapis.com/v1beta1/projects/$P"

step "Firebase project"
if ! api GET "$FB" | grep -q '"projectId"'; then
  api POST "$FB:addFirebase" '{}' >/dev/null
  echo "Added Firebase to $P (waiting 30s)"; sleep 30
fi

step "Firestore (eur3)"
gcloud firestore databases describe --database='(default)' >/dev/null 2>&1 || \
  gcloud firestore databases create --database='(default)' --location=eur3 --type=firestore-native --quiet

step "Buckets (EU, no soft delete so deletions are final)"
for B in "$INCOMING" "$DATA"; do
  gcloud storage buckets describe "gs://$B" >/dev/null 2>&1 || \
    gcloud storage buckets create "gs://$B" --location="$REGION" --uniform-bucket-level-access --public-access-prevention --soft-delete-duration=0
done
cat > /tmp/lifecycle.json <<'JSON'
{"rule":[{"action":{"type":"Delete"},"condition":{"age":7}}]}
JSON
gcloud storage buckets update "gs://$INCOMING" --lifecycle-file=/tmp/lifecycle.json --soft-delete-duration=0 >/dev/null
gcloud storage buckets update "gs://$DATA" --soft-delete-duration=0 >/dev/null
# Uploads bucket is served by Firebase Storage (security rules); the data bucket never is.
api POST "https://firebasestorage.googleapis.com/v1beta/projects/$P/buckets/$INCOMING:addFirebase" '{}' >/dev/null || true
step "Service agents needed by Cloud Functions triggers"
PN="$(gcloud projects describe "$P" --format='value(projectNumber)')"
# Enabling Compute creates the default compute service account that Eventarc checks for.
gcloud services enable compute.googleapis.com --quiet
gcloud beta services identity create --service=pubsub.googleapis.com --quiet >/dev/null 2>&1 || true
gcloud beta services identity create --service=eventarc.googleapis.com --quiet >/dev/null 2>&1 || true
# Asking Cloud Storage for its service account creates it.
echo "Storage service agent: $(api GET "https://storage.googleapis.com/storage/v1/projects/$P/serviceAccount" | tr -d '\n' | head -c 300)"
grant() { # member role
  for attempt in 1 2 3 4 5 6; do
    if gcloud projects add-iam-policy-binding "$P" --member="$1" --role="$2" --condition=None --quiet >/dev/null 2>/tmp/iam.err; then echo "granted $2 to $1"; return 0; fi
    echo "  waiting to grant $2 to $1 (attempt $attempt): $(tail -1 /tmp/iam.err)"; sleep 20
  done
  echo "::warning::could not grant $2 to $1"; return 0
}
grant "serviceAccount:service-$PN@gs-project-accounts.iam.gserviceaccount.com" roles/pubsub.publisher
grant "serviceAccount:service-$PN@gcp-sa-pubsub.iam.gserviceaccount.com" roles/iam.serviceAccountTokenCreator
grant "serviceAccount:$PN-compute@developer.gserviceaccount.com" roles/run.invoker
grant "serviceAccount:$PN-compute@developer.gserviceaccount.com" roles/eventarc.eventReceiver
grant "serviceAccount:service-$PN@gcp-sa-eventarc.iam.gserviceaccount.com" roles/eventarc.serviceAgent
# Functions run as the runtime account, and Eventarc delivers upload events as that account too.
RUNTIME="${GCP_RUNTIME_SA:?GCP_RUNTIME_SA secret missing}"
grant "serviceAccount:$RUNTIME" roles/run.invoker
grant "serviceAccount:$RUNTIME" roles/eventarc.eventReceiver
# "Delete All My Data" queues a Cloud Task from a function running as this account, and the task runs as
# the same account. Without these two the queue call fails with a 403 (iam.serviceAccounts.actAs) and the
# account is left half-deleted.
grant "serviceAccount:$RUNTIME" roles/cloudtasks.enqueuer
if gcloud iam service-accounts add-iam-policy-binding "$RUNTIME" --member="serviceAccount:$RUNTIME" --role=roles/iam.serviceAccountUser --quiet >/dev/null 2>/tmp/iam.err; then
  echo "granted roles/iam.serviceAccountUser on $RUNTIME to itself"
else
  echo "::warning::could not let $RUNTIME act as itself: $(tail -1 /tmp/iam.err)"
fi
# New projects build functions with the default compute account, which needs these roles.
for role in roles/cloudbuild.builds.builder roles/logging.logWriter roles/artifactregistry.writer roles/storage.objectViewer; do
  grant "serviceAccount:$PN-compute@developer.gserviceaccount.com" "$role"
done

step "Anonymous sign-in"
cfg=$(api PATCH "https://identitytoolkit.googleapis.com/admin/v2/projects/$P/config?updateMask=signIn.anonymous.enabled" '{"signIn":{"anonymous":{"enabled":true}}}')
if ! echo "$cfg" | grep -q '"anonymous"'; then
  echo "Initializing Firebase Authentication"
  api POST "https://identitytoolkit.googleapis.com/v2/projects/$P/identityPlatform:initializeAuth" '{}' >/dev/null || true
  cfg=$(api PATCH "https://identitytoolkit.googleapis.com/admin/v2/projects/$P/config?updateMask=signIn.anonymous.enabled" '{"signIn":{"anonymous":{"enabled":true}}}')
  echo "$cfg" | grep -q '"anonymous"' || fail "Could not enable anonymous sign-in: $cfg"
fi

step "iOS app registration"
: "${BUNDLE_ID:?BUNDLE_ID secret missing}"
APP_ID=$(api GET "$FB/iosApps" | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((a['appId'] for a in d.get('apps',[]) if a.get('bundleId')==sys.argv[1]),''))" "$BUNDLE_ID")
if [[ -z "$APP_ID" ]]; then
  api POST "$FB/iosApps" "{\"bundleId\":\"$BUNDLE_ID\",\"displayName\":\"Health Sync\",\"teamId\":\"${APPLE_TEAM_ID:-}\"}" >/dev/null
  sleep 20
  APP_ID=$(api GET "$FB/iosApps" | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((a['appId'] for a in d.get('apps',[]) if a.get('bundleId')==sys.argv[1]),''))" "$BUNDLE_ID")
fi
[[ -n "$APP_ID" ]] || fail "iOS app registration failed"
echo "iOS app: $APP_ID"
[[ -n "${APPLE_TEAM_ID:-}" ]] && api PATCH "$FB/iosApps/$APP_ID?updateMask=teamId" "{\"teamId\":\"$APPLE_TEAM_ID\"}" >/dev/null

step "App Check (App Attest; enforcement stays off until the soak test passes)"
api PATCH "https://firebaseappcheck.googleapis.com/v1/projects/$P/apps/$APP_ID/appAttestConfig?updateMask=tokenTtl" '{"tokenTtl":"3600s"}' >/dev/null || true

step "Keep secret links out of request logs"
FILTER='resource.type="cloud_run_revision" AND (httpRequest.requestUrl:"/mcp/" OR httpRequest.requestUrl:"/analytics-mcp/")'
gcloud logging sinks update _Default --remove-exclusions=mcp-links --quiet >/dev/null 2>&1 || true
gcloud logging sinks update _Default --add-exclusion=name=mcp-links,filter="$FILTER" --quiet >/dev/null

step "Alert email channel"
: "${ALERT_EMAIL:?ALERT_EMAIL secret missing}"
CHANNEL=$(gcloud beta monitoring channels list --filter="labels.email_address=\"$ALERT_EMAIL\"" --format='value(name)' | head -1)
if [[ -z "$CHANNEL" ]]; then
  CHANNEL=$(gcloud beta monitoring channels create --display-name="Health Sync alerts" --type=email --channel-labels=email_address="$ALERT_EMAIL" --format='value(name)')
fi
echo "$CHANNEL" > /tmp/alert-channel

echo; echo "Provisioning complete for $P"
