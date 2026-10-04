"""Save only the age-rating questionnaire; probe privacy API read access."""
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('listing', Path(__file__).with_name('save-draft.py'))
listing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(listing)


class Questionnaires(listing.Apple):
    def call(self, method, path, data=None):
        # Separate exact route policy: no listing updates, builds or submissions.
        read = (path == 'apps/6817135913' or path == 'apps/6817135913/appInfos'
                or path == 'apps/6817135913/dataUsages'
                or re.fullmatch(r'appInfos/[A-Za-z0-9-]+(/ageRatingDeclaration)?', path)
                or re.fullmatch(r'ageRatingDeclarations/[A-Za-z0-9-]+', path))
        write = re.fullmatch(r'ageRatingDeclarations/[A-Za-z0-9-]+', path)
        if not ((method == 'GET' and read) or (method == 'PATCH' and write)):
            raise RuntimeError('Questionnaire endpoint outside scope')
        # Reuse transport without broadening the original draft mutation allowlist.
        import urllib.request
        import urllib.error
        req = urllib.request.Request(listing.ROOT + path, method=method,
            headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'},
            data=json.dumps({'data': data}).encode() if data else None)
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try:
                errors = json.loads(error.read()).get('errors', [])
                detail = '; '.join(str(e.get('code', '')) + ': ' + str(e.get('detail', e.get('title', ''))) for e in errors)
            except Exception:
                detail = 'No structured error'
            raise RuntimeError(f'Apple API HTTP {error.code} on {method} {path}: {detail[:1200]}') from None


def save(api, payload, output):
    if payload['appId'] != '6817135913' or payload['bundleId'] != 'com.vasylyk.krok':
        raise RuntimeError('Unexpected app')
    expected = json.loads(Path(__file__).with_name('questionnaires.json').read_text())['ageRating']
    if payload['ageRating'] != expected:
        raise RuntimeError('Unexpected questionnaire fields')
    output.mkdir(parents=True, exist_ok=True)
    app = api.call('GET', 'apps/6817135913')['data']
    if app['attributes']['bundleId'] != payload['bundleId']:
        raise RuntimeError('Bundle mismatch')
    infos = api.call('GET', 'apps/6817135913/appInfos')['data']
    editable = [i for i in infos if i['attributes'].get('state', i['attributes'].get('appStoreState')) == 'PREPARE_FOR_SUBMISSION']
    if len(editable) != 1:
        raise RuntimeError('No unambiguous editable app info')
    info = editable[0]
    before = api.call('GET', f'appInfos/{info["id"]}/ageRatingDeclaration')['data']
    (output / 'questionnaires-before.json').write_text(json.dumps(before, indent=2))
    attrs = payload['ageRating']
    api.call('PATCH', f'ageRatingDeclarations/{before["id"]}', {
        'type': 'ageRatingDeclarations', 'id': before['id'], 'attributes': attrs})
    after = api.call('GET', f'ageRatingDeclarations/{before["id"]}')['data']
    if any(after['attributes'].get(k) != v for k, v in attrs.items()):
        raise RuntimeError('Age-rating readback mismatch')
    info_after = api.call('GET', f'appInfos/{info["id"]}')['data']
    result = {'ageRating': after, 'computedRating': info_after['attributes'].get('appStoreAgeRating')}
    try:
        privacy = api.call('GET', 'apps/6817135913/dataUsages')
        result['privacyApi'] = {'available': True, 'existingDeclarationCount': len(privacy.get('data', []))}
    except RuntimeError as error:
        result['privacyApi'] = {'available': False, 'reason': str(error)}
    (output / 'questionnaires-after.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        payload = json.loads(Path(__file__).with_name('questionnaires.json').read_text())
        token = subprocess.run([sys.executable, 'scripts/tasks/asc_jwt.py'],
                               capture_output=True, check=True, text=True).stdout.strip()
        save(Questionnaires(token), payload, Path('draft-result'))
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else type(error).__name__, file=sys.stderr)
        sys.exit(1)
