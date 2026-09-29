# Shared helpers for task scripts (sourced). Requires: gcloud authenticated via WIF.
set -euo pipefail
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID secret is missing (see docs/SETUP.md step C)}"
P="$GCP_PROJECT_ID"
REGION="europe-west1"
INCOMING="$P-incoming"
DATA="$P-data"
SIGNING="$P-signing"
BASE_URL="https://$P.web.app"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gcloud config set project "$P" >/dev/null 2>&1
TOKEN() { gcloud auth print-access-token; }
api() { # api METHOD URL [JSON]
  local m=$1 u=$2 d=${3:-}
  if [[ -n "$d" ]]; then
    curl -sS -X "$m" -H "Authorization: Bearer $(TOKEN)" -H "Content-Type: application/json" -H "x-goog-user-project: $P" "$u" -d "$d"
  else
    curl -sS -X "$m" -H "Authorization: Bearer $(TOKEN)" -H "x-goog-user-project: $P" "$u"
  fi
}
step() { echo; echo "==> $*"; }
fail() { echo "::error::$*" >&2; exit 1; }
firebase_cli() { npx --yes firebase-tools@15 "$@" --project "$P" --non-interactive; }
