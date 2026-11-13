"""Writes submission/app-store/listing-en-US.json to the editable App Store listing (en-US): name and subtitle on the
app info, description, keywords and promotional text on the newest iOS version. Never submits for review."""
import json, os, subprocess, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
listing = json.load(open(os.path.join(ROOT, "submission/app-store/listing-en-US.json")))
token = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "asc_jwt.py")],
                       capture_output=True, text=True, check=True).stdout.strip()

def call(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> HTTP {e.code}: {e.read().decode()[:800]}")

app_id = os.environ.get("ASC_APP_ID") or call("GET", f"/v1/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"][0]["id"]

# The editable app info is the one not live on the store (the app has never been released, so there is one).
infos = call("GET", f"/v1/apps/{app_id}/appInfos")["data"]
info = next(i for i in infos if i["attributes"].get("appStoreState") != "READY_FOR_SALE")
loc = next(l for l in call("GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"] if l["attributes"]["locale"] == "en-US")
call("PATCH", f"/v1/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"],
     "attributes": {"name": listing["name"], "subtitle": listing["subtitle"]}}})
print(f"name: {loc['attributes']['name']!r} -> {listing['name']!r}")
print(f"subtitle: {loc['attributes']['subtitle']!r} -> {listing['subtitle']!r}")

version = call("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=1")["data"][0]
vloc = next(l for l in call("GET", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"] if l["attributes"]["locale"] == "en-US")
call("PATCH", f"/v1/appStoreVersionLocalizations/{vloc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": vloc["id"],
     "attributes": {k: listing[k] for k in ("description", "keywords", "promotionalText")}}})
print(f"keywords: {vloc['attributes']['keywords']!r} -> {listing['keywords']!r}")
print("description and promotional text updated for version", version["attributes"]["versionString"])

# Read back what App Store Connect now holds.
after = call("GET", f"/v1/appInfoLocalizations/{loc['id']}")["data"]["attributes"]
vafter = call("GET", f"/v1/appStoreVersionLocalizations/{vloc['id']}")["data"]["attributes"]
ok = after["name"] == listing["name"] and vafter["keywords"] == listing["keywords"] and vafter["description"] == listing["description"]
print("verified" if ok else "MISMATCH after update")
sys.exit(0 if ok else 1)
