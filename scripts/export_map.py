#!/usr/bin/env python3
"""Write the map's spaces to a file served with the site.

Jonathan, 12 Oct 2026: the project went over Supabase's free data
allowance a second month running (7.63 GB of 5 GB). Most of what it
sends is the map's list of spaces, asked for every time someone opens
the map (about 0.85 MB each time). This script asks once, at build
time, and writes the answer to app/build/web/data/map.json, so the
site's own hosting (GitHub Pages) serves it to every visitor at no
cost to the database. The build runs on every upload and once a night.

It asks as a visitor who is not signed in (the anon key), so the file
holds exactly what a signed-out visitor is allowed to see: the same
map_venues() answer, through the same rules. Signed-in people (the
founders, owners, anyone who added a space) still ask the database,
so they see their own pending spaces as before.

If the answer looks wrong (an error, or far fewer spaces than the map
has), no file is written and the app falls back to asking the
database, as it did before. Nothing breaks either way.

Usage: export_map.py <output file>
Report: ci-debug/map_export_report.json
"""
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

# Fewer spaces than this means something went wrong (the map has
# about a thousand).
MIN_SPACES = 300


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'app/build/web/data/map.json'
    url = os.environ.get('SUPABASE_URL', '').rstrip('/')
    key = os.environ.get('SUPABASE_ANON_KEY', '')
    report = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'written': False}
    try:
        if not url or not key:
            raise RuntimeError('SUPABASE_URL or SUPABASE_ANON_KEY missing')
        req = urllib.request.Request(
            f'{url}/rest/v1/rpc/map_venues',
            data=b'{}', method='POST',
            headers={
                'apikey': key,
                'Authorization': f'Bearer {key}',
                'Content-Type': 'application/json',
            })
        with urllib.request.urlopen(req, timeout=120) as r:
            rows = json.loads(r.read().decode('utf-8'))
        if not isinstance(rows, list):
            raise RuntimeError('answer is not a list')
        report['spaces'] = len(rows)
        if len(rows) < MIN_SPACES:
            raise RuntimeError(f'only {len(rows)} spaces, expected at least {MIN_SPACES}')
        body = {
            'generated_at': report['at'],
            'venues': rows,
        }
        os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
        text = json.dumps(body, separators=(',', ':'), ensure_ascii=False)
        with open(out, 'w', encoding='utf-8') as f:
            f.write(text)
        report['written'] = True
        report['bytes'] = len(text.encode('utf-8'))
        print(f'map file: {len(rows)} spaces, {report["bytes"]} bytes -> {out}')
    except (urllib.error.URLError, RuntimeError, ValueError, OSError) as e:
        report['error'] = str(e)
        print(f'map file not written: {e} (the app will ask the database instead)')
    os.makedirs('ci-debug', exist_ok=True)
    with open('ci-debug/map_export_report.json', 'w') as f:
        json.dump(report, f, indent=2)


if __name__ == '__main__':
    main()
