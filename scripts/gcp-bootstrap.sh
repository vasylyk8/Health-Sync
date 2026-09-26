#!/usr/bin/env bash
# One-time Google Cloud setup for Health Sync. Run in Google Cloud Shell:
#   bash gcp-bootstrap.sh <PROJECT_ID>
# Safe to re-run (idempotent). Prints the values to paste into GitHub secrets at the end.
set -euo pipefail

PROJECT_ID="${1:?Usage: bash gcp-bootstrap.sh <PROJECT_ID>}"
GITHUB_REPO="vasylyk8/Health-Sync"
REGION="europe-west1"
POOL="github"
PROVIDER="github-oidc"
DEPLOY_SA="deployer"
RUNTIME_SA="runtime"

gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

echo "==> Checking billing"
if [[ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)')" != "True" ]]; then
  echo "ERROR: billing is not enabled on $PROJECT_ID. Upgrade the Firebase project to the Blaze plan first." >&2
  exit 1
fi

echo "==> Enabling APIs (takes a few minutes)"
gcloud services enable \
  firebase.googleapis.com firestore.googleapis.com firebasestorage.googleapis.com storage.googleapis.com \
  cloudfunctions.googleapis.com run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  eventarc.googleapis.com pubsub.googleapis.com cloudscheduler.googleapis.com cloudtasks.googleapis.com \
  identitytoolkit.googleapis.com firebaseappcheck.googleapis.com firebasehosting.googleapis.com \
  monitoring.googleapis.com logging.googleapis.com secretmanager.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com firebaserules.googleapis.com

echo "==> Service accounts"
for SA in "$DEPLOY_SA" "$RUNTIME_SA"; do
  gcloud iam service-accounts describe "$SA@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "$SA" --display-name="Health Sync $SA"
done
DEPLOY_EMAIL="$DEPLOY_SA@$PROJECT_ID.iam.gserviceaccount.com"
RUNTIME_EMAIL="$RUNTIME_SA@$PROJECT_ID.iam.gserviceaccount.com"

echo "==> Granting deploy roles (used only by GitHub Actions)"
for ROLE in roles/firebase.admin roles/cloudfunctions.admin roles/run.admin roles/iam.serviceAccountUser \
  roles/artifactregistry.admin roles/cloudbuild.builds.editor roles/serviceusage.serviceUsageAdmin \
  roles/monitoring.editor roles/logging.configWriter roles/storage.admin roles/datastore.owner \
  roles/eventarc.admin roles/pubsub.admin roles/cloudscheduler.admin roles/cloudtasks.admin \
  roles/secretmanager.admin roles/firebaseappcheck.admin roles/identitytoolkit.admin \
  roles/resourcemanager.projectIamAdmin roles/iam.serviceAccountAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$DEPLOY_EMAIL" \
    --role="$ROLE" --condition=None --quiet >/dev/null
done

echo "==> Granting runtime roles (used by the running server)"
for ROLE in roles/datastore.user roles/storage.objectAdmin roles/eventarc.eventReceiver \
  roles/cloudtasks.enqueuer roles/firebaseauth.admin roles/logging.logWriter roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$RUNTIME_EMAIL" \
    --role="$ROLE" --condition=None --quiet >/dev/null
done

echo "==> Workload Identity Federation for GitHub ($GITHUB_REPO)"
gcloud iam workload-identity-pools describe "$POOL" --location=global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create "$POOL" --location=global --display-name="GitHub"
gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global \
  --workload-identity-pool="$POOL" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository=='$GITHUB_REPO'"
gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_EMAIL" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/attribute.repository/$GITHUB_REPO" \
  --quiet >/dev/null

echo "==> Checking organization policies that commonly block this setup"
for C in constraints/gcp.resourceLocations constraints/iam.allowedPolicyMemberDomains constraints/run.allowedIngress; do
  if gcloud resource-manager org-policies describe "$C" --project="$PROJECT_ID" --effective 2>/dev/null | grep -q "deny\|allowedValues"; then
    echo "WARNING: org policy $C is set on this project. If deploys fail, ask your Google Cloud admin to allow EU locations, public (allUsers) access and all ingress for this project."
  fi
done

WIF_PROVIDER="projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER"
cat <<EOF

=====================================================================
 Done. Add these as GitHub repository secrets
 (github.com/$GITHUB_REPO -> Settings -> Secrets and variables -> Actions):

   GCP_PROJECT_ID        $PROJECT_ID
   GCP_WIF_PROVIDER      $WIF_PROVIDER
   GCP_DEPLOY_SA         $DEPLOY_EMAIL
   GCP_RUNTIME_SA        $RUNTIME_EMAIL
=====================================================================
EOF
