"""Read-only checks of the deployed PR30 public pages, icon and OAuth discovery."""
import json
import html as html_parser
import re
from pathlib import Path
import struct
import urllib.request
import urllib.error

base = 'https://krok-1d60a.firebaseapp.com'
def read(path, expected_status=200):
    try:
        response = urllib.request.urlopen(base + path, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code != expected_status:
            raise
        response = error
    with response:
        assert response.status == expected_status
        return response.read(), {name.lower(): value for name, value in response.headers.items()}

for path in ['/', '/support', '/privacy', '/mcp-docs', '/connect', '/terms', '/contact-cleanup-missing-page']:
    content, headers = read(path, 404 if path == '/contact-cleanup-missing-page' else 200)
    html = content.decode()
    assert 'KROK' in html and '/icon.png' in html
    decoded = html_parser.unescape(html).lower()
    assert not any(value in decoded for value in ['yule', 'm6s 1e7', 'vasylyk', 'outlook.com']), 'Personal contact information exposed on ' + path
    assert set(re.findall(r'[a-z0-9_.+%-]+@[a-z0-9.-]+\.[a-z]{2,}', decoded)) <= {'support@2ndopinions.ai'}, 'Unexpected public email on ' + path
    assert "img-src 'self' data:" in headers['content-security-policy']
    if path == '/connect':
        script_sources = headers['content-security-policy'].split('script-src ', 1)[1].split(';', 1)[0].split()
        assert 'https://apis.google.com' in script_sources, 'Firebase redirect helper blocked by deployed script policy'
    assert headers['x-content-type-options'] == 'nosniff'
    if path == '/':
        assert 'Your Apple Health, meet your AI.' in html
    if path == '/support':
        assert 'same Apple Account' in html
        assert 'mailto:support@2ndopinions.ai' in html
    if path == '/privacy':
        assert '2ndOp Inc' in html and 'Public assistant connections' in html
        assert 'support@2ndopinions.ai' in html
    if path == '/terms':
        assert 'KROK Terms of Service' in html and 'October 2, 2026' in html
        assert '2ndOp Inc' in html and 'people aged 16 or older' in html
        assert '1 Yule Ave' not in html and 'vasylyk@outlook.com' not in html
        assert 'draft terms' not in html and 'Items for publisher/legal approval' not in html
    print('PASS: deployed public page ' + path)
css, _ = read('/style.css')
assert b'--ink:#3a3a3c' in css and b'--background:#141414' in css
assert b'#e8385e' not in css and b'[hidden]{display:none!important}' in css
icon, _ = read('/icon.png')
assert icon[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', icon[16:24]) == (1024, 1024)
for path, expected in [('/.well-known/oauth-authorization-server', 'issuer'), ('/.well-known/oauth-protected-resource', 'resource')]:
    data, _ = read(path)
    metadata = json.loads(data)
    assert metadata[expected] == base + ('/' if expected == 'issuer' else '/mcp')
print('PASS: PR30 stylesheet/icon and canonical OAuth discovery after deploy')

challenge_path = Path(__file__).resolve().parents[2] / 'firebase/hosting/.well-known/openai-apps-challenge'
if challenge_path.exists():
    body, headers = read('/.well-known/openai-apps-challenge')
    assert body == challenge_path.read_bytes(), 'Portal challenge response differs from approved token'
    assert headers['content-type'].startswith('text/plain')
    assert headers['cache-control'] == 'no-store'
    print('PASS: exact plain-text OpenAI domain challenge on canonical MCP origin')
