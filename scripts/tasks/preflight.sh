#!/usr/bin/env bash
# Checks every credential and permission the unattended build needs. Prints a checklist; exits
# non-zero if anything the owner must fix is missing.
source "$(dirname "$0")/lib.sh"
problems=()
ok() { echo "  ✅ $*"; }
bad() { echo "  ❌ $*"; problems+=("$*"); }

step "Google Cloud"
gcloud projects describe "$P" >/dev/null 2>&1 && ok "project $P reachable via GitHub OIDC" || bad "cannot access project $P (check GCP_* secrets / B4 script)"
# The deploy account usually may not read billing status; a real billing problem shows up at deploy.
case "$(gcloud billing projects describe "$P" --format='value(billingEnabled)' 2>/dev/null)" in
  True) ok "billing enabled" ;;
  False) bad "billing not enabled (Blaze plan, B2)" ;;
  *) echo "  ⚠️  billing status not readable by the deploy account (fine if the project is on Blaze)" ;;
esac
for s in cloudfunctions run firestore firebasestorage eventarc cloudtasks identitytoolkit firebaseappcheck monitoring secretmanager; do
  gcloud services list --enabled --format='value(config.name)' 2>/dev/null | grep -q "^$s.googleapis.com$" && ok "API $s" || bad "API $s not enabled (re-run B4 script)"
done
for c in constraints/gcp.resourceLocations constraints/iam.allowedPolicyMemberDomains; do
  if gcloud resource-manager org-policies describe "$c" --project "$P" --effective 2>/dev/null | grep -q 'allowedValues\|deniedValues'; then
    echo "  ⚠️  org policy $c is set; deploy may fail if it blocks EU locations or public access"
  fi
done

step "Apple"
for v in APPLE_TEAM_ID BUNDLE_ID ASC_APP_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do [[ -n "${!v:-}" ]] && ok "$v set" || bad "$v secret missing (C)"; done
if [[ -n "${ASC_KEY_P8:-}" && -n "${ASC_KEY_ID:-}" ]]; then
  JWT=$(python3 "$ROOT/scripts/tasks/asc_jwt.py" 2>/dev/null || true)
  if [[ -n "$JWT" ]]; then
    code=$(curl -sg -o /tmp/asc.json -w '%{http_code}' -H "Authorization: Bearer $JWT" "https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=$BUNDLE_ID")
    [[ "$code" == 200 ]] && ok "App Store Connect API key works" || bad "App Store Connect API key rejected (HTTP $code)"
    grep -q "\"bundleId\" *: *\"$BUNDLE_ID\"" /tmp/asc.json && ok "app record for $BUNDLE_ID exists" || bad "no App Store Connect app with bundle id $BUNDLE_ID (A4)"
    code=$(curl -sg -o /tmp/certs.json -w '%{http_code}' -H "Authorization: Bearer $JWT" "https://api.appstoreconnect.apple.com/v1/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION")
    [[ "$code" == 200 ]] && ok "key has Admin-level access (needed for cloud signing)" || bad "key lacks Admin role (A5)"
    for email in ${TESTER_EMAILS//,/ }; do
      code=$(curl -sg -o /tmp/user.json -w '%{http_code}' -H "Authorization: Bearer $JWT" "https://api.appstoreconnect.apple.com/v1/users?filter[username]=$email")
      if grep -qi "\"username\" *: *\"$email\"" /tmp/user.json; then ok "tester $email is an App Store Connect user"
      else
        code=$(curl -sg -o /tmp/inv.json -w '%{http_code}' -H "Authorization: Bearer $JWT" "https://api.appstoreconnect.apple.com/v1/userInvitations?filter[email]=$email")
        if grep -qi "$email" /tmp/inv.json; then echo "  ⚠️  $email was invited to App Store Connect but hasn't accepted yet (needed for TestFlight)"
        else bad "$email is not an App Store Connect user (A7)"; fi
      fi
    done
  else
    bad "could not build an App Store Connect token from ASC_KEY_P8 (paste the whole .p8 file)"
  fi
fi

step "AI keys (weekly evals)"
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && ok "ANTHROPIC_API_KEY set" || bad "ANTHROPIC_API_KEY missing"
[[ -n "${OPENAI_API_KEY:-}" ]] && ok "OPENAI_API_KEY set" || bad "OPENAI_API_KEY missing"
[[ -n "${ALERT_EMAIL:-}" ]] && ok "ALERT_EMAIL set" || bad "ALERT_EMAIL missing"

echo
if (( ${#problems[@]} )); then
  echo "Preflight found ${#problems[@]} problem(s):"; printf ' - %s\n' "${problems[@]}"; exit 1
fi
echo "Preflight passed."
