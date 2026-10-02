"""Read-only Apple/Firebase configuration check. Never prints private keys or tokens."""
import json
import os
import subprocess
import urllib.request

required = ["APPLE_SIGN_IN_SERVICE_ID", "APPLE_SIGN_IN_KEY_ID", "APPLE_SIGN_IN_KEY_P8", "APPLE_TEAM_ID", "BUNDLE_ID", "GCP_PROJECT_ID"]
missing = [name for name in required if not os.environ.get(name)]
if missing:
    raise SystemExit("Missing configuration names: " + ", ".join(missing))
if os.environ["APPLE_TEAM_ID"] != "AAZHPDPD2B" or os.environ["BUNDLE_ID"] != "com.vasylyk.krok":
    raise SystemExit("Apple Team ID or bundle ID differs from the owner's confirmed KROK identity.")
if "BEGIN PRIVATE KEY" not in os.environ["APPLE_SIGN_IN_KEY_P8"]:
    raise SystemExit("Sign in with Apple key does not have the expected PEM format.")
token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
project = os.environ["GCP_PROJECT_ID"]
url = f"https://identitytoolkit.googleapis.com/admin/v2/projects/{project}/defaultSupportedIdpConfigs/apple.com"
request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
with urllib.request.urlopen(request) as response:
    config = json.load(response)
if not config.get("enabled"):
    raise SystemExit("Apple authentication is not enabled in Firebase.")
if config.get("clientId") != os.environ["APPLE_SIGN_IN_SERVICE_ID"]:
    raise SystemExit("Firebase Apple Services ID does not match APPLE_SIGN_IN_SERVICE_ID.")
print("Apple provider is enabled; Services ID matches the CI configuration.")
print("Confirmed KROK bundle ID: com.vasylyk.krok; Team ID: AAZHPDPD2B.")
print("Private-key presence checked without revealing its contents.")
