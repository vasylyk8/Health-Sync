"""Explicit owner-approved provider change only. Default is read-only.

Changes only signIn.email.enabled and signIn.email.passwordRequired in KROK.
Do not call --apply until owner approval is recorded in the conversation.
"""
import argparse
import json
import os
import subprocess
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--apply', action='store_true')
args = parser.parse_args()
if os.environ.get('GCP_PROJECT_ID') != 'krok-1d60a':
    raise SystemExit('Confirmed KROK project required.')
token = subprocess.check_output(['gcloud', 'auth', 'print-access-token'], text=True).strip()
if os.environ.get('GITHUB_ACTIONS') == 'true':
    print('::add-mask::' + token, flush=True)
url = 'https://identitytoolkit.googleapis.com/admin/v2/projects/krok-1d60a/config'
headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
    current = json.load(response).get('signIn', {}).get('email', {})
print(json.dumps({'enabled': bool(current.get('enabled')), 'passwordRequired': bool(current.get('passwordRequired'))}))
if args.apply:
    request = urllib.request.Request(url + '?updateMask=signIn.email.enabled,signIn.email.passwordRequired', headers=headers,
        method='PATCH', data=json.dumps({'signIn': {'email': {'enabled': True, 'passwordRequired': True}}}).encode())
    with urllib.request.urlopen(request, timeout=30) as response:
        changed = json.load(response).get('signIn', {}).get('email', {})
    if not (changed.get('enabled') and changed.get('passwordRequired')):
        raise SystemExit('Provider update did not enable the requested settings.')
    print('Explicit provider change applied; Apple sign-in and authorization claim checks are unchanged.')
else:
    print('Read-only check. No provider setting changed.')
