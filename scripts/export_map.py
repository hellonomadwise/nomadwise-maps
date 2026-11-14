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
import shutil
import sys
import urllib.error
import urllib.request

# Fewer spaces than this means something went wrong (the map has
# about a thousand).
MIN_SPACES = 300


def fill_chat_box(web_dir, url, key):
    """The chat box on nomadwise.io (web/chat.js, migration 190) needs
    the database's public address and public key, the same two the app
    is built with. They are written into the built file here, so they
    live in GitHub's secrets only. Without them the box stays hidden."""
    # The price cards on the listing pages (web/prices.js, migration
    # 243) need the same two.
    # The "Stop monthly updates" page (web/stop/stop.js, migration 253)
    # too.
    # And the short claim links (web/c.js, migration 287).
    for name in ('chat.js', 'prices.js', 'c.js', os.path.join('stop', 'stop.js')):
        path = os.path.join(web_dir, name)
        try:
            if not url or not key or not os.path.exists(path):
                continue
            with open(path, encoding='utf-8') as f:
                text = f.read()
            text = (text.replace('__NW_SUPABASE_URL__', url)
                        .replace('__NW_SUPABASE_KEY__', key))
            with open(path, 'w', encoding='utf-8') as f:
                f.write(text)
            print(f'{name}: filled in')
        except OSError as e:
            print(f'{name} not filled in: {e}')


def site_was_built(web_dir, url, key):
    """True when the build before this step made the site.

    14 Nov 2026: nomadmaps.io answered "404 File not found" for hours.
    The step that builds the site sends its output through "tee", so
    when the build itself fails the step still counts as passed; this
    script then made app/build/web/data/ for the map file, and that
    nearly empty folder went live as the whole site.

    So before anything is written: the folder must hold the app's page
    and its program. If not, the folder is taken away, which makes the
    upload step fail and stops the run before it goes live. The site
    that was live stays live, the run is reported as failed, and the
    end of the build's own log is printed here and sent to app_events
    (name ci_site_not_built) so the reason can be read without opening
    GitHub."""
    has_page = os.path.exists(os.path.join(web_dir, 'index.html'))
    has_app = any(os.path.exists(os.path.join(web_dir, n))
                  for n in ('main.dart.js', 'main.dart.mjs', 'main.dart.wasm'))
    if has_page and has_app:
        return True
    print(f'THE SITE WAS NOT BUILT: {web_dir} has '
          f'{"no index.html" if not has_page else "no main.dart.js"}. '
          'Nothing goes live from this run; the site that is live stays.')
    tail = ''
    try:
        with open('ci_debug.log', encoding='utf-8', errors='replace') as f:
            tail = f.read()[-6000:]
    except OSError as e:
        tail = f'(no ci_debug.log: {e})'
    # nothing of ours in what leaves the runner
    for secret in (key, os.environ.get('GOOGLE_PLACES_KEY', '')):
        if secret:
            tail = tail.replace(secret, '***')
    print('---- the end of the build log ----')
    print(tail)
    print('---- end ----')
    try:
        if url and key:
            req = urllib.request.Request(
                f'{url}/rest/v1/app_events',
                data=json.dumps({
                    'anon_id': 'ci-build',
                    'name': 'ci_site_not_built',
                    'props': {
                        'run': os.environ.get('GITHUB_RUN_NUMBER', ''),
                        'sha': os.environ.get('GITHUB_SHA', '')[:7],
                        'event': os.environ.get('GITHUB_EVENT_NAME', ''),
                        'has_page': has_page,
                        'has_app': has_app,
                        'tail': tail[-4000:],
                    },
                }).encode('utf-8'),
                method='POST',
                headers={
                    'apikey': key,
                    'Authorization': f'Bearer {key}',
                    'Content-Type': 'application/json',
                    'Prefer': 'return=minimal',
                })
            urllib.request.urlopen(req, timeout=30).close()
    except (urllib.error.URLError, ValueError, OSError) as e:
        print(f'(the note to app_events did not go: {e})')
    shutil.rmtree(web_dir, ignore_errors=True)
    return False


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'app/build/web/data/map.json'
    url = os.environ.get('SUPABASE_URL', '').rstrip('/')
    key = os.environ.get('SUPABASE_ANON_KEY', '')
    web_dir = os.path.dirname(os.path.dirname(out))
    if not site_was_built(web_dir, url, key):
        sys.exit(1)
    fill_chat_box(web_dir, url, key)
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
