"""Provision only KROK's dedicated reviewer; credentials stay in Secret Manager/in memory.

Existing credentials are reused; no implicit rotation during platform review.
The explicit --apply flag is required for cloud writes. No customer account is touched.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--apply', action='store_true')
args = parser.parse_args()
project = os.environ.get('GCP_PROJECT_ID')
if project != 'krok-1d60a':
    raise SystemExit('Refusing to operate outside the confirmed KROK project.')
if not args.apply:
    print('Dry-run: dedicated synthetic reviewer, Secret Manager credentials, provider and production checks. No writes.')
    raise SystemExit(0)
root = Path(__file__).resolve().parents[2]
token = subprocess.check_output(['gcloud', 'auth', 'print-access-token'], text=True).strip()
def mask(value):
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        print('::add-mask::' + value, flush=True)
mask(token)

def api(url, method='GET', body=None, allow_missing=False):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404 and allow_missing:
            return None
        # Never echo an API response/request that could contain credentials.
        raise RuntimeError(f'Cloud API {method} failed with HTTP {error.code}; inspect permissions/configuration.') from None

secret_base = f'https://secretmanager.googleapis.com/v1/projects/{project}/secrets'
secret_name = 'krok-directory-reviewer-credentials'
metadata = api(secret_base + '/' + secret_name, allow_missing=True)
if metadata is None:
    api(secret_base + '?secretId=' + secret_name, 'POST', {'replication': {'automatic': {}}})
saved = api(secret_base + '/' + secret_name + '/versions/latest:access', allow_missing=True)
if saved is None:
    credentials = {'uid': 'krok-reviewer-directory', 'email': 'directory-reviewer@krok.invalid',
                   'password': secrets.token_urlsafe(36)}
    for value in credentials.values():
        mask(value)
    api(secret_base + '/' + secret_name + ':addVersion', 'POST',
        {'payload': {'data': base64.b64encode(json.dumps(credentials).encode()).decode()}})
else:
    credentials = json.loads(base64.b64decode(saved['payload']['data']))
    for value in credentials.values():
        mask(value)
if credentials.get('uid') != 'krok-reviewer-directory' or credentials.get('email') != 'directory-reviewer@krok.invalid' or len(credentials.get('password', '')) < 32:
    raise SystemExit('Stored reviewer credentials do not match the dedicated synthetic identity.')

config_url = f'https://identitytoolkit.googleapis.com/admin/v2/projects/{project}/config'
config = api(config_url)
email_config = config.get('signIn', {}).get('email', {})
provider_enabled = bool(email_config.get('enabled') and email_config.get('passwordRequired'))
# Read-only: never broaden project-wide sign-in methods through reviewer provisioning.
# Any provider change requires separate explicit owner authorization.

env = {**os.environ, 'KROK_REVIEWER_UID': credentials['uid'], 'KROK_REVIEWER_EMAIL': credentials['email'],
       'KROK_REVIEWER_PASSWORD': credentials['password']}
subprocess.run(['node', 'firebase/functions/scripts/prepare-reviewer.mjs', '--apply', '--reuse'], cwd=root, env=env, check=True)
if not provider_enabled:
    Path('/tmp/krok-reviewer-verification.json').write_text(json.dumps({'syntheticOnly': True,
        'accountProvisioned': True, 'emailPasswordProviderEnabled': False,
        'productionBrowserAndTools': 'Blocked: owner approval is required to enable the project-wide email/password provider. No provider setting was changed.'}, indent=2))
    raise SystemExit('Dedicated reviewer provisioned. Production login is blocked because email/password sign-in is disabled; no global authentication setting was changed.')
subprocess.run(['node', 'firebase/functions/scripts/verify-reviewer.mjs'], cwd=root, env=env, check=True)
print('Reviewer credentials are stored only in KROK Secret Manager. See the credential-free verification artifact.')
