#!/usr/bin/env python3
"""One pass over the pages Nomad Maps has put photos on: any photo that
is not yet a WebP of 90 KB or less is swapped for its WebP copy
(scripts/web_photos.py, which keeps the quality up).

Which pages: every listing whose photos came from Nomad Maps (pasted or
uploaded in the control centre, or the owner's own photos). Photos on
other pages are left exactly as they are.

Per page: read its Images entry on Webflow, convert the photos that need
it (from Webflow's own copy), write the new links into the same slots
with the same alt text, and publish the entry again if it was live.

The report (ci-debug/web_photos_redo.json, also on the sync-reports
branch) lists what changed and, separately, photos too small to look
sharp at any setting (under 800 pixels wide), which need replacing.

    python3 scripts/web_photos_redo.py            # do it
    python3 scripts/web_photos_redo.py --dry-run  # only list
"""
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import web_photos  # noqa: E402

DRY = '--dry-run' in sys.argv
SB = os.environ.get('SUPABASE_URL', '').rstrip('/')
KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
TOKEN = os.environ.get('WEBFLOW_API_TOKEN', '')
COLLECTION_ID = '65fa86d0e0379bf78d52448d'
IMAGES_ID = '65fa86d0e0379bf78d52451b'
SLOTS = ('image', 'image-2', 'image-3', 'image-4', 'image-5')
MIN_WIDTH = 800

report = {'started': datetime.datetime.now(
    datetime.timezone.utc).isoformat(), 'dry_run': DRY, 'pages_checked': 0,
    'pages_changed': [], 'photos_converted': 0, 'already_fine': 0,
    'too_small': [], 'errors': []}


def call(url, headers, method='GET', body=None):
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    url, data=data, method=method, headers=headers),
                    timeout=60) as r:
                t = r.read().decode()
                return json.loads(t) if t else None
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 3:
                time.sleep(int(e.headers.get('Retry-After', '15')) + 1)
                continue
            raise


def wf(path, method='GET', body=None):
    time.sleep(1.1)  # Webflow allows 60 calls a minute
    return call('https://api.webflow.com' + path, {
        'Authorization': f'Bearer {TOKEN}', 'accept': 'application/json',
        'Content-Type': 'application/json'}, method, body)


def sb(path):
    return call(f'{SB}/rest/v1/{path}', {'apikey': KEY,
                                        'Authorization': f'Bearer {KEY}'})


def size_of(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(
                url, method='HEAD'), timeout=20) as r:
            return int(r.headers.get('Content-Length') or 0)
    except Exception:  # noqa: BLE001
        return 0


def fine(url):
    """Already a WebP of 90 KB or less."""
    path = urllib.parse.urlparse(url).path.lower()
    if not path.endswith('.webp'):
        return False
    n = size_of(url)
    return 0 < n <= web_photos.LIMIT


def finish():
    report['finished'] = datetime.datetime.now(
        datetime.timezone.utc).isoformat()
    report['converted_detail'] = conv.log if conv else []
    os.makedirs('ci-debug', exist_ok=True)
    with open('ci-debug/web_photos_redo.json', 'w') as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report, indent=2))
    sys.exit(0)


conv = None
if not (SB and KEY and TOKEN):
    report['errors'].append('missing SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY '
                            'or WEBFLOW_API_TOKEN; nothing changed')
    finish()
conv = web_photos.WebPhotos(SB, KEY)

venues, offset = [], 0
while True:
    page = sb('venues?select=id,name,webflow_cms_id,website_photos,'
              'owner_content&webflow_cms_id=not.is.null'
              f'&order=name&limit=1000&offset={offset}') or []
    venues += page
    if len(page) < 1000:
        break
    offset += 1000
ours = [v for v in venues
        if [u for u in (v.get('website_photos') or []) if str(u).strip()]
        or ((v.get('owner_content') or {}).get('photos'))]

for v in ours:
    try:
        item = wf(f"/v2/collections/{COLLECTION_ID}/items/{v['webflow_cms_id']}")
        fd = (item or {}).get('fieldData') or {}
        img_id = fd.get('image-reference')
        if not img_id or item.get('isArchived'):
            continue
        img = wf(f'/v2/collections/{IMAGES_ID}/items/{img_id}') or {}
        ifd = img.get('fieldData') or {}
        report['pages_checked'] += 1
        slug = fd.get('slug') or v['name']
        patch, done = {}, []
        for key in SLOTS:
            val = ifd.get(key)
            url = val.get('url') if isinstance(val, dict) else None
            if not url:
                continue
            if fine(url):
                report['already_fine'] += 1
                continue
            if DRY:
                done.append(key)
                continue
            before = len(conv.log)
            new = conv.convert(url, slug)
            facts = conv.log[before] if len(conv.log) > before else {}
            if facts.get('source_size'):
                w = int(facts['source_size'].split('x')[0])
                if w < MIN_WIDTH:
                    report['too_small'].append({'page': slug, 'slot': key,
                                                'width': w})
            if new == url:
                continue
            patch[key] = {'url': new, 'alt': val.get('alt') or ''}
            done.append(key)
        if patch:
            wf(f'/v2/collections/{IMAGES_ID}/items/{img_id}', 'PATCH',
               {'fieldData': patch})
            if not img.get('isDraft') and img.get('lastPublished'):
                wf(f'/v2/collections/{IMAGES_ID}/items/publish', 'POST',
                   {'itemIds': [img_id]})
        if done:
            report['photos_converted'] += len(done)
            report['pages_changed'].append({'page': slug,
                                            'slots': done})
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f"{v.get('name')}: {str(e)[:200]}")

finish()
