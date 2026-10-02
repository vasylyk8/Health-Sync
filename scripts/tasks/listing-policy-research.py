"""Capture public submission sources for inspection; never assert policy eligibility automatically."""
import datetime
import json
import pathlib
import urllib.error
import urllib.request
from html.parser import HTMLParser

class Content(HTMLParser):
    def __init__(self):
        super().__init__()
        self.skip = 0
        self.text = []
        self.links = []
    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'nav', 'header', 'footer'):
            self.skip += 1
        if tag == 'a':
            href = dict(attrs).get('href', '')
            if any(word in href.lower() for word in ('submit', 'submission', 'partner', 'directory', 'guideline', 'policy', 'privacy', 'platform.openai.com', 'security')):
                self.links.append(href)
    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'nav', 'header', 'footer'):
            self.skip = max(0, self.skip - 1)
    def handle_data(self, data):
        if not self.skip and data.strip():
            self.text.append(data.strip())

sources = {
    'openai-guidelines': 'https://developers.openai.com/apps-sdk/app-submission-guidelines/',
    'openai-submission': 'https://developers.openai.com/apps-sdk/deploy/submission/',
    'anthropic-directory': 'https://claude.com/connectors',
    'anthropic-submission': 'https://claude.com/docs/connectors/building/submission',
    'anthropic-directory-policy': 'https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy',
    'anthropic-mcp': 'https://docs.claude.com/en/docs/mcp',
    'krok-website': 'https://krok-1d60a.firebaseapp.com/',
    'krok-support': 'https://krok-1d60a.firebaseapp.com/support',
    'krok-privacy': 'https://krok-1d60a.firebaseapp.com/privacy',
}
out = pathlib.Path('policy-research')
out.mkdir(exist_ok=True)
index = []
for name, url in sources.items():
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 KROKSubmissionPreparation/1.0'})
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode('utf-8', errors='replace')
            final_url, status = response.url, response.status
        page = Content()
        page.feed(raw)
        (out / (name + '.txt')).write_text('Source: ' + url + '\nFinal URL: ' + final_url + '\nFetched: ' + datetime.datetime.now(datetime.timezone.utc).isoformat() + '\n\n' + '\n'.join(page.text) + '\n\nRelevant links:\n' + '\n'.join(sorted(set(page.links))))
        index.append({'name': name, 'url': url, 'final_url': final_url, 'status': status, 'text_characters': sum(map(len, page.text))})
    except Exception as error:
        index.append({'name': name, 'url': url, 'error': str(error)})
(out / 'index.json').write_text(json.dumps(index, indent=2))
print(json.dumps(index, indent=2))
