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

# Matching client IDs alone does not validate Apple's server-side code exchange.
# Report only equality/presence flags; provider responses can contain private keys.
apple = config.get("appleSignInConfig", {}).get("codeFlowConfig", {})
checks = {
    "Firebase Apple team matches KROK": apple.get("teamId") == os.environ["APPLE_TEAM_ID"],
    "Firebase Apple signing key ID matches CI": apple.get("keyId") == os.environ["APPLE_SIGN_IN_KEY_ID"],
    "Firebase Apple private key configured": bool(apple.get("privateKey")),
}
if apple.get("privateKey"):
    def public_key(private_key):
        result = subprocess.run(["openssl", "pkey", "-pubout"], input=private_key,
                                text=True, capture_output=True)
        return result.stdout.strip() if result.returncode == 0 else None
    expected_public = public_key(os.environ["APPLE_SIGN_IN_KEY_P8"])
    checks["Firebase Apple private key matches CI"] = bool(expected_public) and public_key(apple["privateKey"]) == expected_public
for name, passed in checks.items():
    print(("PASS: " if passed else "FAIL: ") + name)
if not all(checks.values()):
    raise SystemExit("Firebase Apple signing configuration is incomplete or differs from KROK's configured credentials. No provider settings were changed.")
print("Apple portal check still required: Services ID must use com.vasylyk.krok as its primary App ID and include the active Firebase return URL. This preflight does not verify Apple's consent branding or a live Apple account login.")

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
        # Cross-check the registry directly: do not confuse a filter issue with missing access.
        registry = apple_get("bundleIds?limit=200")
        bundles = [item for item in registry["data"] if item["attributes"].get("identifier") == "com.vasylyk.krok"]
        if len(bundles) != 1:
            apps = apple_get("apps?filter%5BbundleId%5D=com.vasylyk.krok")["data"]
            print("KROK App Store record visible to the configured API key: " + ("yes" if apps else "no"))
            print("Visible App ID registry entries in this page: " + str(len(registry["data"])))
            if registry.get("links", {}).get("next"):
                print("Registry is paginated; App ID capability was not conclusively verified.")
            raise SystemExit("Confirmed KROK App ID not visible to the configured App Store Connect API key. Check its publishing account and provisioning access before release.")
    capabilities = apple_get("bundleIds/" + bundles[0]["id"] + "/bundleIdCapabilities")["data"]
    if not any(item["attributes"].get("capabilityType") == "APPLE_ID_AUTH" for item in capabilities):
        raise SystemExit("Sign in with Apple capability is missing on the confirmed KROK App ID.")
    print("Apple Developer App ID exists and its Sign in with Apple capability is enabled (read-only check).")
else:
    print("::warning::App Store Connect secrets unavailable; native App ID capability was not independently verified.")
