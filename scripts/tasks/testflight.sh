#!/usr/bin/env bash
# Builds, signs and uploads the iOS app to TestFlight (macOS runner).
source "$(dirname "$0")/lib.sh"
: "${BUNDLE_ID:?}" "${APPLE_TEAM_ID:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_P8:?}"
cd "$ROOT/ios"
command -v xcodegen >/dev/null || brew install xcodegen

step "Firebase config for the app"
APP_ID=$(api GET "https://firebase.googleapis.com/v1beta1/projects/$P/iosApps" | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((a['appId'] for a in d.get('apps',[]) if a.get('bundleId')==sys.argv[1]),''))" "$BUNDLE_ID")
[[ -n "$APP_ID" ]] || fail "iOS app not registered in Firebase; run the deploy task first"
api GET "https://firebase.googleapis.com/v1beta1/projects/$P/iosApps/$APP_ID/config" \
  | python3 -c "import json,sys,base64; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)['configFileContents']))" > HealthSync/GoogleService-Info.plist
grep -q "$BUNDLE_ID" HealthSync/GoogleService-Info.plist || fail "could not download GoogleService-Info.plist"

step "Signing + upload"
export MATCH_PASSWORD="$(gcloud secrets versions access latest --secret=match-password)"
export MATCH_BUCKET="$SIGNING" PUBLIC_BASE_URL="$BASE_URL"
bundle install --quiet
bundle exec fastlane beta
