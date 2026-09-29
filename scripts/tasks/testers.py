"""Adds TESTER_EMAILS to an internal TestFlight group ("Team", all builds) via the App Store Connect API.
Prints Apple's own error text when something is refused."""
import json, os, subprocess, sys, urllib.error, urllib.parse, urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
TOKEN = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "asc_jwt.py")], capture_output=True, text=True, check=True).stdout.strip()

def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

def errors(doc):
    return "; ".join(f"{e.get('code')}: {e.get('detail')}" for e in doc.get("errors", [])) or json.dumps(doc)[:300]

bundle = os.environ["BUNDLE_ID"]
_, apps = call("GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle}))
app_id = apps["data"][0]["id"]

_, groups = call("GET", f"/apps/{app_id}/betaGroups?limit=50")
group = next((g for g in groups.get("data", []) if g["attributes"].get("isInternalGroup")), None)
if group:
    print(f"using internal group '{group['attributes']['name']}'")
else:
    code, doc = call("POST", "/betaGroups", {"data": {"type": "betaGroups",
        "attributes": {"name": "Team", "isInternalGroup": True, "hasAccessToAllBuilds": True},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    if code >= 300:
        sys.exit(f"could not create internal group ({code}): {errors(doc)}")
    group = doc["data"]
    print("created internal group 'Team' (all builds)")
gid = group["id"]

_, members = call("GET", f"/betaGroups/{gid}/betaTesters?limit=200")
in_group = {m["attributes"].get("email", "").lower() for m in members.get("data", [])}

failed = 0
for n, email in enumerate(e.strip() for e in os.environ.get("TESTER_EMAILS", "").split(",") if e.strip()):
    if email.lower() in in_group:
        print(f"tester {n + 1}: already in the group")
        continue
    _, found = call("GET", "/betaTesters?" + urllib.parse.urlencode({"filter[email]": email}))
    if found.get("data"):
        code, doc = call("POST", f"/betaGroups/{gid}/relationships/betaTesters", {"data": [{"type": "betaTesters", "id": found["data"][0]["id"]}]})
    else:
        code, doc = call("POST", "/betaTesters", {"data": {"type": "betaTesters", "attributes": {"email": email},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}})
    if code < 300:
        print(f"tester {n + 1}: added")
    else:
        failed += 1
        print(f"tester {n + 1}: refused ({code}): {errors(doc)}")
sys.exit(1 if failed else 0)
