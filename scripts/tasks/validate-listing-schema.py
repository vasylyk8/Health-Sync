"""Validate upload bytes against fetched Agent Plugins schemas and ISO targeting.

OpenAI extension fields still require portal validation; the portable schemas
deliberately do not define those client-specific semantics.
"""
import argparse
import json
from pathlib import Path
import zipfile
import jsonschema
import pycountry

parser = argparse.ArgumentParser()
parser.add_argument('archive', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
with zipfile.ZipFile(args.archive) as archive:
    for name in ('plugin', 'mcp'):
        schema = json.loads((root / 'submission' / 'schemas' / (name + '.schema.json')).read_text())
        jsonschema.Draft202012Validator.check_schema(schema)
        manifest = json.loads(archive.read('krok-health/' + name + '.json'))
        jsonschema.Draft202012Validator(schema).validate(manifest)
    plugin = json.loads(archive.read('krok-health/plugin.json'))
    countries = plugin['extensions']['com.openai']['publication']['countries']
    expected = sorted(country.alpha_2 for country in pycountry.countries if country.alpha_2 not in {'RU', 'BY'})
    assert countries == expected, 'Country allowlist must implement the owner-selected all-except-RU/BY restriction'
print('Actual ZIP passed official portable schema checks and explicit ISO country restriction. Portal eligibility/extension checks remain separate.')
