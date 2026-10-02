"""Read-only Apple/Firebase configuration check. Never prints private keys or tokens."""
import json
import os
from pathlib import Path
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
key_check = subprocess.run(["openssl", "pkey", "-check", "-noout"], input=os.environ["APPLE_SIGN_IN_KEY_P8"], text=True, capture_output=True)
if key_check.returncode:
    raise SystemExit("Sign in with Apple private key could not be parsed or validated.")
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
print("Private-key format and integrity validated without revealing its contents.")

# Reuse the existing App Store Connect signer, capturing its token instead of logging it.
if all(os.environ.get(name) for name in ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8"]):
    asc_token = subprocess.check_output(["python3", str(Path(__file__).with_name("asc_jwt.py"))], text=True).strip()
    def apple_get(path):
        request = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/" + path,
                                         headers={"Authorization": "Bearer " + asc_token})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    bundles = apple_get("bundleIds?filter%5Bidentifier%5D=com.vasylyk.krok")["data"]
    if len(bundles) != 1:
        raise SystemExit("The confirmed KROK bundle ID was not found in the publishing Apple account.")
    capabilities = apple_get("bundleIds/" + bundles[0]["id"] + "/bundleIdCapabilities")["data"]
    if not any(item["attributes"].get("capabilityType") == "APPLE_ID_AUTH" for item in capabilities):
        raise SystemExit("Sign in with Apple capability is missing on the confirmed KROK App ID.")
    print("Apple Developer App ID exists and its Sign in with Apple capability is enabled (read-only check).")
else:
    print("::warning::App Store Connect secrets unavailable; native App ID capability was not independently verified.")
