"""Save public listing metadata only; never attach a build or submit a version."""
import json
import hashlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = 'https://api.appstoreconnect.apple.com/v1/'
ALLOWED = {'apps', 'appStoreVersions', 'appStoreVersionLocalizations',
           'appInfos', 'appInfoLocalizations'}


class Apple:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, data=None):
        # Explicit allowlist excludes submission, builds, privacy and legal endpoints.
        if method not in {'GET', 'POST', 'PATCH'} or path.split('/')[0].split('?')[0] not in ALLOWED:
            raise RuntimeError('Endpoint outside draft scope')
        if method != 'GET' and path.split('/')[0] not in {
                'appStoreVersions', 'appStoreVersionLocalizations', 'appInfoLocalizations'}:
            raise RuntimeError('Mutation outside listing scope')
        req = urllib.request.Request(ROOT + path, method=method,
            headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'},
            data=json.dumps({'data': data}).encode() if data else None)
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Neither request headers nor credential-bearing error bodies enter logs.
            try:
                errors = json.loads(error.read()).get('errors', [])
                details = '; '.join(str(e.get('code', '')) + ': ' + str(e.get('detail', e.get('title', ''))) for e in errors)
            except Exception:
                details = 'No structured error'
            raise RuntimeError(f'Apple API HTTP {error.code} on {method} {path.split("?")[0]}: {details[:1200]}') from None

    def many(self, path):
        result = []
        while path:
            page = self.call('GET', path)
            result.extend(page['data'])
            next_url = page.get('links', {}).get('next')
            if next_url and not next_url.startswith(ROOT):
                raise RuntimeError('Unexpected pagination host')
            path = next_url[len(ROOT):] if next_url else None
        return result


def validate(payload):
    if payload['bundleId'] != 'com.vasylyk.krok' or payload['locale'] != 'en-US':
        raise RuntimeError('Unexpected app or locale')
    if not re.fullmatch(r'\d+\.\d+(\.\d+)?', payload['versionString']):
        raise RuntimeError('Invalid version')
    limits = {'description': 4000, 'keywords': 100, 'promotionalText': 170,
              'name': 30, 'subtitle': 30}
    for key, maximum in limits.items():
        value = {**payload['appInfo'], **payload['versionLocalization']}[key]
        if not value or len(value) > maximum:
            raise RuntimeError('Invalid listing field: ' + key)
    if set(payload['appInfo']) != {'name', 'subtitle', 'privacyPolicyUrl'}:
        raise RuntimeError('Unexpected app info fields')
    if set(payload['versionLocalization']) != {
            'description', 'keywords', 'promotionalText', 'supportUrl', 'marketingUrl'}:
        raise RuntimeError('Unexpected version fields')
    for group in ('appInfo', 'versionLocalization'):
        for key, value in payload[group].items():
            if key.endswith('Url') and not value.startswith('https://krok-1d60a.web.app/'):
                raise RuntimeError('Unexpected public URL')


def save(api, payload, output):
    validate(payload)
    output.mkdir(parents=True, exist_ok=True)
    apps = api.many('apps?' + urllib.parse.urlencode({'filter[bundleId]': payload['bundleId']}))
    if len(apps) != 1:
        raise RuntimeError('Expected exactly one existing KROK app')
    app = apps[0]
    versions = api.many(f'apps/{app["id"]}/appStoreVersions?filter[platform]=IOS')
    drafts = [v for v in versions if v['attributes'].get('appStoreState') == 'PREPARE_FOR_SUBMISSION']
    if len(drafts) > 1 or (not drafts and versions):
        raise RuntimeError('No unambiguous editable first-release draft')
    before = {'appId': app['id'], 'versions': versions, 'localizations': [], 'appInfoLocalizations': []}
    if drafts:
        version = drafts[0]
        before['localizations'] = api.many(f'appStoreVersions/{version["id"]}/appStoreVersionLocalizations')
    infos = api.many(f'apps/{app["id"]}/appInfos')
    editable_infos = [i for i in infos if i['attributes'].get('appStoreState') == 'PREPARE_FOR_SUBMISSION']
    info = editable_infos[0] if len(editable_infos) == 1 else None
    if info:
        before['appInfoLocalizations'] = api.many(f'appInfos/{info["id"]}/appInfoLocalizations')
    (output / 'before.json').write_text(json.dumps(before, indent=2))
    if not drafts:
        version = api.call('POST', 'appStoreVersions', {
            'type': 'appStoreVersions', 'attributes': {'platform': 'IOS',
                'versionString': payload['versionString'], 'releaseType': 'MANUAL'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': app['id']}}}})['data']
    else:
        api.call('PATCH', f'appStoreVersions/{version["id"]}', {
            'type': 'appStoreVersions', 'id': version['id'], 'attributes': {'releaseType': 'MANUAL'}})
    results = {'appId': app['id'], 'versionId': version['id'], 'verified': [], 'skipped': []}
    def localize(kind, parent_type, parent_id, existing, attributes):
        found = [item for item in existing if item['attributes'].get('locale') == payload['locale']]
        if len(found) > 1:
            raise RuntimeError('Duplicate localization')
        data = {'type': kind, 'attributes': dict(attributes)}
        if found:
            data['id'] = found[0]['id']
            saved = api.call('PATCH', f'{kind}/{data["id"]}', data)['data']
        else:
            data['attributes']['locale'] = payload['locale']
            relationship = 'appStoreVersion' if parent_type == 'appStoreVersions' else 'appInfo'
            data['relationships'] = {relationship: {'data': {'type': parent_type, 'id': parent_id}}}
            saved = api.call('POST', kind, data)['data']
        actual = api.call('GET', f'{kind}/{saved["id"]}')['data']
        if any(actual['attributes'].get(k) != v for k, v in attributes.items()):
            raise RuntimeError('Readback verification failed')
        results['verified'].append(actual)
        (output / 'after.json').write_text(json.dumps(results, indent=2))
    localize('appStoreVersionLocalizations', 'appStoreVersions', version['id'],
             before['localizations'], payload['versionLocalization'])
    if info:
        try:
            localize('appInfoLocalizations', 'appInfos', info['id'],
                     before['appInfoLocalizations'], payload['appInfo'])
        except RuntimeError as error:
            if not str(error).startswith('Apple API HTTP 409'):
                raise
            results['skipped'].append(str(error))
            if 'ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE.DIFFERENT_ACCOUNT' in str(error):
                # Preserve Apple's current app name; choosing a replacement needs the owner.
                attrs = {k: v for k, v in payload['appInfo'].items() if k != 'name'}
                localize('appInfoLocalizations', 'appInfos', info['id'],
                         before['appInfoLocalizations'], attrs)
                results['existingAppNames'] = [item['attributes'].get('name')
                    for item in before['appInfoLocalizations']
                    if item['attributes'].get('locale') == payload['locale']]
    else:
        results['skipped'].append('App-wide metadata: editable app-info state not confirmed')
    state = api.call('GET', f'appStoreVersions/{version["id"]}')['data']
    if state['attributes'].get('appStoreState') != 'PREPARE_FOR_SUBMISSION' or state['attributes'].get('releaseType') != 'MANUAL':
        raise RuntimeError('Draft/manual-release verification failed')
    results['version'] = state
    (output / 'after.json').write_text(json.dumps(results, indent=2))
    print(json.dumps({'appId': app['id'], 'versionId': version['id'],
        'versionString': state['attributes']['versionString'],
        'state': state['attributes']['appStoreState'], 'releaseType': state['attributes']['releaseType'],
        'verified': [{'type': item['type'], 'fields': {
            key: {'sha256': hashlib.sha256(value.encode()).hexdigest(), 'characters': len(value)}
            if key == 'description' else value for key, value in item['attributes'].items()
            if key in {**payload['appInfo'], **payload['versionLocalization']}}}
            for item in results['verified']], 'existingAppNames': results.get('existingAppNames', []),
        'skipped': results['skipped']}))


if __name__ == '__main__':
    try:
        payload = json.loads(Path('scratch-app-store/draft-listing.json').read_text())
        validate(payload)
        token = subprocess.run([sys.executable, 'scripts/tasks/asc_jwt.py'],
                               capture_output=True, check=True, text=True).stdout.strip()
        save(Apple(token), payload, Path('draft-result'))
    except Exception as error:
        if isinstance(error, RuntimeError):
            print(str(error), file=sys.stderr)
        else:
            print('Draft operation failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
