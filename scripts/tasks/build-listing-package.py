"""Build and inspect a credential-free preparation ZIP, with explicit readiness gaps.

This validates local inventory/metadata, not platform acceptance or external URLs.
Run --require-ready before final handoff; it rejects missing review requirements.
"""
import argparse
import json
from pathlib import Path
import re
import struct
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=Path('/tmp/krok-health-preparation.zip'))
parser.add_argument('--require-ready', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
source = root / 'submission' / 'krok-health'
assert not args.output.resolve().is_relative_to(source.resolve()), 'Archive must be outside source'
inventory = {'plugin.json', 'mcp.json', 'assets/icon.png'}
files = list(source.rglob('*'))
assert not any(p.is_symlink() for p in files), 'Symlinks are forbidden'
assert {str(p.relative_to(source)) for p in files if p.is_file()} == inventory, 'Unexpected upload contents'
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(inventory):
        archive.write(source / name, 'krok-health/' + name)

# Inspect the actual archive, not only the files that produced it.
with zipfile.ZipFile(args.output) as archive:
    assert set(archive.namelist()) == {'krok-health/' + name for name in inventory}
    manifest = json.loads(archive.read('krok-health/plugin.json'))
    mcp = json.loads(archive.read('krok-health/mcp.json'))
    assert manifest['name'] == 'krok-health'
    assert re.fullmatch(r'\d+\.\d+\.\d+', manifest['version'])
    assert manifest.get('apps') is None and manifest['extensions']['com.openai'].get('apps') is None
    assert not any(key in manifest for key in ('hooks', 'skills', 'mcpServers', 'interface'))
    info = manifest['extensions']['com.openai']
    listing = info['interface']
    for field, limit in [('displayName', 30), ('shortDescription', 30), ('developerName', 80), ('longDescription', 4000)]:
        assert isinstance(listing[field], str) and 0 < len(listing[field]) <= limit, field
    prompts = listing['defaultPrompt']
    assert 1 <= len(prompts) <= 3
    assert all(isinstance(p, str) and p.strip() and '\n' not in p and len(p) <= 128 and '@' not in p for p in prompts)
    assert len({' '.join(p.split()) for p in prompts}) == len(prompts)
    for field in ('websiteURL', 'supportURL', 'privacyPolicyURL', 'termsOfServiceURL'):
        if field in listing:
            assert listing[field].startswith('https://') and '@' not in listing[field] and len(listing[field]) <= 1024
    for field in ('logo', 'composerIcon'):
        assert listing[field] == './assets/icon.png'
    png = archive.read('krok-health/assets/icon.png')
    assert png[:8] == b'\x89PNG\r\n\x1a\n' and len(png) <= 5 * 1024 * 1024
    width, height = struct.unpack('>II', png[16:24])
    assert width == height and 256 <= width <= 4096
    assert mcp['mcpServers'] == {'krok-health': {'type': 'streamable-http', 'url': 'https://krok-1d60a.firebaseapp.com/mcp'}}
    cases = info['review']['test_cases']
    for group, count in [('positive', 5), ('negative', 3)]:
        assert len(cases[group]) == count
        for case in cases[group]:
            required = ['description', 'prompt'] + (['tools_triggered', 'expected_behavior'] if group == 'positive' else [])
            assert all(isinstance(case.get(k), str) and case[k].strip() for k in required)
    assert info['review']['commerce'] is False

gaps = []
for present, message in [
    ('termsOfServiceURL' in listing, 'Approved, published and verified terms URL'),
    ('demo_recording_url' in info['review'], 'Verified real-host demo recording URL'),
    (bool(info.get('publication', {}).get('countries')), 'Explicit supported-country allowlist excluding RU/BY'),
    ('category' in listing, 'Category confirmed in target portal'),
]:
    if not present:
        gaps.append(message)
print(json.dumps({'archive': str(args.output), 'local_inventory_and_metadata': 'passed', 'icon': [width, height],
                  'package_gaps': gaps, 'external_checks': 'Public URL content, health-data eligibility, real-host cases, reviewer login, verification, scans and attestations remain required.'}, indent=2))
if args.require_ready:
    parser.error('Readiness also requires recorded external evidence; this preparation command cannot certify submission readiness.' + (' Missing: ' + '; '.join(gaps) if gaps else ''))
