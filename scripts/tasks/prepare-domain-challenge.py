"""Stage only an actual portal-issued token, preserving other challenges/discovery.

Read the challenge from stdin, never invent it. This stages a static Hosting file;
deployment and verification of the portal-selected origin remain separate actions.
"""
import argparse
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True, choices=['krok-1d60a.firebaseapp.com', 'krok-1d60a.web.app'])
args = parser.parse_args()
token = sys.stdin.read()
if not token or token != token.strip() or any(c.isspace() for c in token) or len(token) > 4096:
    parser.error('Provide the exact nonblank single-token portal challenge with no whitespace/newline.')
if any(c in token for c in '<>{}'):
    parser.error('Challenge must be plain text, not HTML/JSON.')
root = Path(__file__).resolve().parents[2]
destination = root / 'firebase/hosting/.well-known/openai-apps-challenge'
if destination.exists() and destination.read_text() != token:
    parser.error('A different challenge already exists; do not replace another submission token.')
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(token)
print('Challenge staged for portal origin https://' + args.host + '/.well-known/openai-apps-challenge. Deploy and verify exact response bytes before confirming domain ownership. OAuth discovery was not modified.')
