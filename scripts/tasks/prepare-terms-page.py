"""Render the existing publisher-review draft; publication is an explicit final step.

Default output is a local preview outside Hosting. --publish-approved writes the
same service text to Hosting only after publisher approval is recorded.
"""
import argparse
import html
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--publish-approved', action='store_true')
parser.add_argument('--output', type=Path, default=Path('/tmp/krok-terms-preview.html'))
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
source = (root / 'docs/legal/TERMS_OF_SERVICE.md').read_text()
paragraphs = []
for line in source.splitlines():
    if line == '## Items for publisher/legal approval':
        break
    if line.startswith('## '):
        paragraphs.append('<h2>' + html.escape(line[3:]) + '</h2>')
    elif line and not line.startswith('# ') and not line.startswith('This is a proposed first-release'):
        paragraphs.append('<p>' + html.escape(line) + '</p>')
warning = '' if args.publish_approved else '<div class="card"><p><strong>Draft for 2ndOp Inc approval.</strong> This local preview is not a published agreement or a completed listing URL. Review the age, countries and consumer-law decisions in the source document before approving publication.</p></div>'
page = '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KROK Terms of Service</title><link rel="stylesheet" href="/style.css"><link rel="icon" type="image/png" href="/icon.png"></head><body><a class="skip" href="#main">Skip to content</a><header class="top"><a class="brand" href="/"><img src="/icon.png" alt="" width="32" height="32">KROK</a><nav aria-label="Main"><a href="/support">Support</a><a href="/privacy">Privacy</a></nav></header><main id="main"><h1>KROK Terms of Service</h1>'''
page += warning + '\n'.join(paragraphs) + '<p><a href="/privacy">Privacy policy</a> · <a href="/support">Support</a></p></main><footer class="foot">© 2ndOp Inc</footer></body></html>\n'
destination = root / 'firebase/hosting/terms.html' if args.publish_approved else args.output
if not args.publish_approved and destination.resolve().is_relative_to((root / 'firebase/hosting').resolve()):
    parser.error('Draft previews must remain outside deployable Hosting files.')
destination.write_text(page)
print(('Approved terms source staged for deployment: ' if args.publish_approved else 'Local draft preview only: ') + str(destination))
