import hashlib
import base64
import http.cookiejar
import json
import secrets
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://krok-1d60a.firebaseapp.com'
RESOURCE = BASE + '/mcp'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect())

def request(path, body=None, form=False, headers=None, client=opener):
    h = dict(headers or {})
    data = None
    if body is not None:
        data = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
        h['Content-Type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
    req = urllib.request.Request(BASE + path, data=data, headers=h)
    try:
        response = client.open(req, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    raw = response.read().decode()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        payload = raw
    return response.code, response.headers, payload

def check(ok, label):
    if not ok:
        raise AssertionError(label)
    print('PASS ' + label, flush=True)

status, headers, metadata = request('/.well-known/oauth-authorization-server')
check(status == 200 and metadata['issuer'] == BASE + '/', 'canonical authorization discovery')
check(metadata['token_endpoint_auth_methods_supported'] == ['none'], 'public PKCE authentication metadata')
check('S256' in metadata['code_challenge_methods_supported'], 'S256 discovery')
check('no-store' in headers.get('Cache-Control', ''), 'authorization metadata is not cached')
for path in ['/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource/mcp']:
    status, _, payload = request(path)
    check(status == 200 and payload['resource'] == RESOURCE and BASE + '/' in payload['authorization_servers'], 'resource discovery ' + path)
status, headers, _ = request('/mcp', {'jsonrpc':'2.0', 'id':1, 'method':'tools/list'}, headers={'Accept':'application/json, text/event-stream'})
check(status == 401 and 'resource_metadata=' in headers.get('WWW-Authenticate', ''), 'unauthenticated MCP requests require OAuth')
for path in ['/health', '/', '/support', '/privacy', '/mcp-docs', '/connect', '/connect.js', '/__/auth/handler']:
    status, headers, payload = request(path)
    check(status == 200, 'public page or Firebase auth helper ' + path)
    if path == '/connect':
        check("script-src 'self'" in headers.get('Content-Security-Policy', ''), 'consent page has production CSP')
status, _, payload = request('/register', {'redirect_uris':['https://example.com/callback'], 'token_endpoint_auth_method':'none'})
check(status == 400 and payload.get('error') == 'invalid_client_metadata', 'untrusted callback registration rejected')
callback = 'https://claude.ai/api/mcp/auth_callback'
status, _, client = request('/register', {'redirect_uris':[callback], 'client_name':'KROK release smoke (no account access)', 'token_endpoint_auth_method':'none'})
check(status == 201 and client.get('client_id') and 'client_secret' not in client, 'supported public client registration')
challenge = base64.urlsafe_b64encode(hashlib.sha256(secrets.token_urlsafe(48).encode()).digest()).decode().rstrip('=')
state = secrets.token_urlsafe(16)
query = urllib.parse.urlencode({'response_type':'code', 'client_id':client['client_id'], 'redirect_uri':callback, 'code_challenge':challenge, 'code_challenge_method':'S256', 'resource':RESOURCE, 'state':state})
status, headers, _ = request('/authorize?' + query)
check(status == 302 and headers.get('Location', '').startswith(BASE + '/connect?request='), 'authorization opens same-origin consent')
check(any(c.name == '__session' and c.secure for c in jar), 'secure consent binding cookie issued')
request_id = urllib.parse.parse_qs(urllib.parse.urlparse(headers['Location']).query)['request'][0]
status, _, payload = request('/oauth/request/' + request_id)
check(status == 200 and payload['provider'] == 'claude', 'Firebase Hosting forwards bound consent cookie')
check('health:events:read' not in payload['scopes'] and 'health:profile:read' not in payload['scopes'] and 'health:routes:full' not in payload['scopes'], 'sensitive permissions excluded from defaults')
unsigned = urllib.request.build_opener(NoRedirect())
status, _, _ = request('/oauth/request/' + request_id, client=unsigned)
check(status == 400, 'unbound consent request rejected')
status, _, _ = request('/oauth/consent', {'request':request_id, 'approve':True}, headers={'Origin':BASE})
check(status == 401, 'account approval requires authenticated Apple identity')
status, _, _ = request('/oauth/consent', {'request':request_id, 'approve':False}, headers={'Origin':'https://example.com'})
check(status == 403, 'cross-origin consent rejected')
status, _, payload = request('/oauth/consent', {'request':request_id, 'approve':False}, headers={'Origin':BASE})
redirect = urllib.parse.urlparse(payload.get('redirect', ''))
params = urllib.parse.parse_qs(redirect.query)
check(status == 200 and redirect.netloc == 'claude.ai' and params.get('error') == ['access_denied'] and params.get('state') == [state] and 'code' not in params, 'cancel preserves state and creates no authorization code')
status, _, _ = request('/oauth/request/' + request_id)
check(status == 400, 'finished consent cannot be replayed')
status, _, payload = request('/token', {'grant_type':'authorization_code', 'client_id':client['client_id'], 'code':secrets.token_urlsafe(32), 'redirect_uri':callback, 'code_verifier':secrets.token_urlsafe(48), 'resource':RESOURCE}, form=True)
check(status == 400 and payload.get('error') == 'invalid_grant', 'invented authorization code rejected')
print('Public release smoke completed; no user login, health access or grant created.', flush=True)
