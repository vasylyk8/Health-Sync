"""Re-sends the open iOS review submission that has unresolved issues (after a rejection), once the App Store version
has the expected build attached. Owner-approved submissions only: set EXPECT_BUILD to the build number."""
import json, os, subprocess, sys, urllib.request

expect = os.environ.get("EXPECT_BUILD", "82")
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
version = call("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=1&include=build")
v = version["data"][0]
build = next((i for i in version.get("included", []) if i["type"] == "builds"), None)
built = build["attributes"]["version"] if build else None
print(f"version {v['attributes']['versionString']} state={v['attributes']['appStoreState']} build={built}")
if built != expect:
    sys.exit(f"Expected build {expect} on the version, found {built}; not submitting")

subs = call("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&filter[platform]=IOS&limit=10")["data"]
open_sub = next((s for s in subs if s["attributes"]["state"] in ("UNRESOLVED_ISSUES", "READY_FOR_REVIEW")), None)
if not open_sub:
    sys.exit("No open review submission to re-send: " + ", ".join(f"{s['id']}={s['attributes']['state']}" for s in subs))
print(f"re-sending submission {open_sub['id']} (state {open_sub['attributes']['state']})")
res = call("PATCH", f"/v1/reviewSubmissions/{open_sub['id']}",
           {"data": {"type": "reviewSubmissions", "id": open_sub["id"], "attributes": {"submitted": True}}})
print("now:", res["data"]["attributes"]["state"], "submitted", res["data"]["attributes"].get("submittedDate"))
