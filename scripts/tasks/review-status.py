"""Read-only App Store Connect query: app versions, their review states, review submissions and builds."""
import json, os, subprocess, sys, urllib.request

token = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "asc_jwt.py")],
                       capture_output=True, text=True, check=True).stdout.strip()

def get(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print(f"GET {path} -> HTTP {e.code}: {e.read().decode()[:300]}")
        return {"data": []}

app_id = os.environ.get("ASC_APP_ID")
if not app_id:
    apps = get(f"/v1/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"]
    app_id = apps[0]["id"]
print("App", app_id)

print("\n== App Store versions ==")
for v in get(f"/v1/apps/{app_id}/appStoreVersions?limit=10&include=build")["data"]:
    a = v["attributes"]
    print(f"{a.get('platform')} {a.get('versionString')}: appStoreState={a.get('appStoreState')} "
          f"appVersionState={a.get('appVersionState')} created={a.get('createdDate')}")

print("\n== Review submissions ==")
subs = get(f"/v1/reviewSubmissions?filter[app]={app_id}&limit=10&include=items")
for s in subs["data"]:
    a = s["attributes"]
    print(f"{s['id']}: state={a.get('state')} platform={a.get('platform')} submitted={a.get('submittedDate')}")
    for it in get(f"/v1/reviewSubmissions/{s['id']}/items")["data"]:
        print(f"   item {it['id']}: state={it['attributes'].get('state')}")

print("\n== Recent builds ==")
for b in get(f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5")["data"]:
    a = b["attributes"]
    print(f"build {a.get('version')}: processing={a.get('processingState')} uploaded={a.get('uploadedDate')} expired={a.get('expired')}")
