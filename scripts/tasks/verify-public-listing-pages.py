"""Read-only checks of the deployed PR30 public pages, icon and OAuth discovery."""
import json
import struct
import urllib.request

base = 'https://krok-1d60a.firebaseapp.com'
def read(path):
    with urllib.request.urlopen(base + path, timeout=30) as response:
        assert response.status == 200
        return response.read(), dict(response.headers)

for path in ['/', '/support', '/privacy', '/mcp-docs', '/connect']:
    content, headers = read(path)
    html = content.decode()
    assert 'KROK' in html and '/icon.png' in html
    assert "img-src 'self' data:" in headers['Content-Security-Policy']
    assert headers['X-Content-Type-Options'] == 'nosniff'
    if path == '/':
        assert 'Your Apple Health, meet your AI.' in html
    if path == '/support':
        assert 'same Apple Account' in html
    if path == '/privacy':
        assert '2ndOp Inc' in html and 'Public assistant connections' in html
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
