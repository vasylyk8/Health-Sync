#!/usr/bin/env bash
# READ-ONLY audit of what the server stores for one real user (matched by the SHA-256 of the opaque
# profile id, never by name). The repo is public, so nothing readable is printed: the result is
# gzipped and encrypted with scripts/tasks/audit-pubkey.pem (only the requester holds the private key).
source "$(dirname "$0")/lib.sh"
step "install duckdb"
python3 -m pip install --quiet duckdb
step "audit"
export AUDIT_PUBKEY="$ROOT/scripts/tasks/audit-pubkey.pem"
python3 - <<'PY'
import os, json, gzip, hashlib, subprocess, urllib.request, urllib.parse, urllib.error, tempfile, zoneinfo, datetime, collections
import duckdb

P = os.environ['GCP_PROJECT_ID']; DATA = P + '-data'
WANT = 'c0862a7f46568a71009bb98bbf29ff9afef394948ae14562b580031354f05712'
TZ = zoneinfo.ZoneInfo('America/Toronto')
WIN_FROM, WIN_TO = '2026-09-19', '2026-10-03'
tok = subprocess.check_output(['gcloud', 'auth', 'print-access-token']).decode().strip()
out = {'errors': []}
def err(where, e): out['errors'].append(f'{where}: {type(e).__name__}: {str(e)[:300]}'); print('ERR', where, type(e).__name__)
def http(url):
    r = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + tok, 'x-goog-user-project': P})
    return urllib.request.urlopen(r, timeout=120).read()
FS = f'https://firestore.googleapis.com/v1/projects/{P}/databases/(default)/documents'
def dec(v):
    k, x = next(iter(v.items()))
    if k == 'nullValue': return None
    if k == 'integerValue': return int(x)
    if k == 'mapValue': return {a: dec(b) for a, b in x.get('fields', {}).items()}
    if k == 'arrayValue': return [dec(i) for i in x.get('values', [])]
    return x
def fdoc(path):
    try:
        d = json.loads(http(f'{FS}/{urllib.parse.quote(path, safe="/()")}'))
        return {a: dec(b) for a, b in d.get('fields', {}).items()}
    except urllib.error.HTTPError as e:
        if e.code == 404: return None
        raise

# 1. find the user without printing ids
uid = None; tok_pg = ''; n_users = 0
while True:
    d = json.loads(http(f'{FS}/users?pageSize=300&mask.fieldPaths=oauthProfileId' + (f'&pageToken={tok_pg}' if tok_pg else '')))
    for dd in d.get('documents', []):
        n_users += 1
        pid = dd.get('fields', {}).get('oauthProfileId', {}).get('stringValue')
        if pid and hashlib.sha256(pid.encode()).hexdigest() == WANT: uid = dd['name'].split('/')[-1]
    tok_pg = d.get('nextPageToken')
    if not tok_pg: break
print('users scanned:', n_users, 'matched:', bool(uid))
if not uid:
    out['errors'].append('user not found')
else:
    work = tempfile.mkdtemp()
    def fetch(path):
        loc = os.path.join(work, hashlib.md5(path.encode()).hexdigest() + '.parquet')
        if not os.path.exists(loc):
            open(loc, 'wb').write(http(f'https://storage.googleapis.com/storage/v1/b/{DATA}/o/{urllib.parse.quote(path, safe="")}?alt=media'))
        return loc
    out['user'] = {k: v for k, v in (fdoc(f'users/{uid}') or {}).items() if k in ('categories', 'tz', 'lastVisibleAt', 'generation', 'deleting', 'createdAt')}
    con = duckdb.connect()
    mans = {}
    TYPES = ['_daily', '_daily_nutrition', '_daily_mind', '_daily_cycle', '_hourly', 'HKWorkoutTypeIdentifier', '_events_nutrition', '_events_profile', '_events_heart', '_events_devices', '_events_mind', '_events_medications']
    out['manifests'] = {}
    for t in TYPES:
        try:
            m = fdoc(f'users/{uid}/types/{t}')
            if not m: out['manifests'][t] = None; continue
            mans[t] = m
            out['manifests'][t] = {'records': m.get('records'), 'partitions': {p: len(f) for p, f in (m.get('files') or {}).items()}, 'coverage': m.get('coverage')}
        except Exception as e: err('manifest ' + t, e)
    def files_of(t, minpart=None):
        res = []
        for p, fl in ((mans.get(t) or {}).get('files') or {}).items():
            if p.startswith('_tomb'): continue
            if minpart and p < minpart: continue
            res += [f['path'] for f in fl]
        return res
    def rows_of(t, where, minpart=None, cols='*'):
        fs = [fetch(p) for p in files_of(t, minpart)]
        if not fs: return []
        c = con.execute(f"select {cols} from read_parquet(?, union_by_name=true) where {where}", [fs])
        names = [d[0] for d in c.description]
        return [dict(zip(names, r)) for r in c.fetchall()]
    # 2. daily rows merged like the server (later upload wins per metric)
    try:
        by_day = {}
        for t in [x for x in TYPES if x.startswith('_daily')]:
            rs = rows_of(t, "k = 'day'", cols='id, extra, seq, batch')
            rs.sort(key=lambda r: (r['seq'] or 0, r['batch'] or ''))
            for r in rs:
                m = (json.loads(r['extra']) if r['extra'] else {}).get('m') or {}
                by_day.setdefault(r['id'], {}).update(m)
        keys = collections.defaultdict(lambda: {'days': 0, 'first': None, 'last': None})
        for day in sorted(by_day):
            for k, v in by_day[day].items():
                if v is None: continue
                ks = keys[k]; ks['days'] += 1; ks['first'] = ks['first'] or day; ks['last'] = day
        out['daily_key_history'] = keys
        out['daily_window'] = {d: by_day[d] for d in sorted(by_day) if WIN_FROM <= d <= WIN_TO}
    except Exception as e: err('daily', e)
    # 3. hourly rows -> per local day aggregates
    try:
        agg = collections.defaultdict(lambda: {'n': 0, 'sum_v': 0.0, 'min_lo': None, 'max_hi': None})
        for r in rows_of('_hourly', "k = 'hs'", minpart='2026-09', cols='agg, s, v, v2, v3, seq'):
            d = datetime.datetime.fromtimestamp(r['s'] / 1000, TZ).strftime('%Y-%m-%d')
            if not (WIN_FROM <= d <= WIN_TO): continue
            a = agg[(r['agg'], d)]; a['n'] += 1; a['sum_v'] += r['v'] or 0
            if r['v2'] is not None: a['min_lo'] = r['v2'] if a['min_lo'] is None else min(a['min_lo'], r['v2'])
            if r['v3'] is not None: a['max_hi'] = r['v3'] if a['max_hi'] is None else max(a['max_hi'], r['v3'])
        out['hourly_window'] = {f'{s}|{d}': v for (s, d), v in sorted(agg.items())}
        out['hourly_series_present'] = sorted({s for s, _ in agg})
    except Exception as e: err('hourly', e)
    # 4. workouts: summaries and raw-stream index (what is stored vs. what the phone expected)
    try:
        ws = {}
        for r in rows_of('HKWorkoutTypeIdentifier', "k = 'w'", minpart='2026-09'):
            if r['id'] not in ws or (r['seq'] or 0) >= (ws[r['id']]['seq'] or 0): ws[r['id']] = r
        lo = int(datetime.datetime.fromisoformat(WIN_FROM).replace(tzinfo=TZ).timestamp() * 1000)
        res = []
        for w in sorted(ws.values(), key=lambda r: r['s']):
            if w['s'] < lo: continue
            ex = json.loads(w['extra']) if w['extra'] else {}
            doc = fdoc(f"users/{uid}/workouts/{w['id']}") or {}
            streams = {n: {'points': s.get('points'), 'unit': s.get('unit'), 'cols': s.get('cols'), 'gen': s.get('gen'), 'files': len(s.get('files') or [])} for n, s in (doc.get('streams') or {}).items()}
            res.append({'id': w['id'], 's': w['s'], 'e': w['e'], 'v': w['v'], 'v2': w['v2'], 'v3': w['v3'], 'u': w['u'], 'src': w['src'], 'dev': w['dev'],
                        'extra_keys': sorted(ex), 'act': ex.get('act'), 'actName': ex.get('actName'), 'dur': ex.get('dur'), 'en': ex.get('en'), 'dist': ex.get('dist'),
                        'hrAvg': ex.get('hrAvg'), 'hrMax': ex.get('hrMax'), 'stats': ex.get('stats'), 'md': ex.get('md'), 'ev_count': len(ex.get('ev') or []),
                        'raw': {'rawComplete': doc.get('rawComplete'), 'expected': doc.get('expected'), 'streams': streams}})
        out['workouts'] = res
    except Exception as e: err('workouts', e)
    # 5. opt-in event logs (counts only)
    try:
        ev = {}
        for t in [x for x in TYPES if x.startswith('_events')]:
            if t not in mans: continue
            fs = [fetch(p) for p in files_of(t)]
            if fs:
                c = con.execute("select agg, count(*), min(s), max(s) from read_parquet(?, union_by_name=true) where k = 'ev' group by agg", [fs])
                ev[t] = {a: [n, lo_, hi_] for a, n, lo_, hi_ in c.fetchall()}
        out['events'] = ev
    except Exception as e: err('events', e)

blob = gzip.compress(json.dumps(out, default=str).encode())
open('/tmp/audit.bin', 'wb').write(blob)
print('payload bytes (gz):', len(blob), 'errors:', len(out['errors']), [e.split(':')[0] for e in out['errors'][:8]])
PY
openssl smime -encrypt -binary -aes-256-cbc -in /tmp/audit.bin -outform PEM "$AUDIT_PUBKEY" > /tmp/audit.enc
echo "-----BEGIN-ENCRYPTED-AUDIT-----"; cat /tmp/audit.enc; echo "-----END-ENCRYPTED-AUDIT-----"
