#!/usr/bin/env python3
"""Apply any new supabase/migrationNN_*.sql files to the database.

Runs in CI on every build. Uses the apply_migration() runner
(installed by migration 42): each file is applied exactly once and
recorded in schema_migrations, so re-runs are no-ops. If the runner
is not installed yet, this politely does nothing.

Output: ci-debug/migrations_report.json
"""
import glob
import json
import os
import re
import urllib.error
import urllib.request

SUPABASE_URL = os.environ['SUPABASE_URL'].rstrip('/')
SERVICE_KEY = os.environ['SUPABASE_SERVICE_ROLE_KEY']


def rpc(name, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f'{SUPABASE_URL}/rest/v1/rpc/{name}',
        data=data, method='POST',
        headers={
            'apikey': SERVICE_KEY,
            'Authorization': f'Bearer {SERVICE_KEY}',
            'Content-Type': 'application/json',
        })
    with urllib.request.urlopen(req) as resp:
        txt = resp.read().decode()
        return json.loads(txt) if txt else None


here = os.path.dirname(__file__)
files = glob.glob(os.path.join(here, '..', 'supabase', 'migration*.sql'))


def key(path):
    m = re.match(r'migration(\d+)([a-z]?)', os.path.basename(path))
    return (int(m.group(1)), m.group(2)) if m else (0, '')


files.sort(key=key)

results = []
error = None
for path in files:
    name = os.path.basename(path)
    sql = open(path).read()
    try:
        out = rpc('apply_migration', {'p_name': name, 'p_sql': sql})
        if out == 'applied':
            results.append({'file': name, 'status': 'applied'})
            print(f'applied: {name}')
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:300]
        if 'apply_migration' in detail and e.code == 404:
            error = ('runner not installed yet (migration 42) — '
                     'nothing changed')
            break
        # A migration that fails must stop the chain: later ones may
        # depend on it. The error surfaces in the report for fixing.
        results.append({'file': name, 'status': 'FAILED',
                        'error': detail})
        error = f'{name} failed'
        break

report = {
    'newly_applied': [r for r in results if r['status'] == 'applied'],
    'failed': [r for r in results if r['status'] == 'FAILED'],
    'error': error,
}
os.makedirs('ci-debug', exist_ok=True)
with open('ci-debug/migrations_report.json', 'w') as fh:
    json.dump(report, fh, indent=2)
print(json.dumps(report, indent=2))
