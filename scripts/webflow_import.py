#!/usr/bin/env python3
"""One-way import: nomadwise.io Webflow listings -> Nomadmaps venues.

Reads scripts/webflow_import_data.json (extracted from the Webflow CMS,
published listings only) and inserts every listing whose Google Place ID
is not yet known to Nomadmaps — neither as a venue nor as a discovered
place. Never writes anything back to Webflow.

Safety properties:
  * idempotent — already-imported or already-existing places are skipped,
    so it can run on every build without creating duplicates
  * reversible — every inserted row carries source='nomadwise-webflow';
    to undo:  delete from venues where source = 'nomadwise-webflow';
  * needs migration37 (venues.source column) — exits politely if missing

Output: ci-debug/webflow_import_report.json
"""
import json
import os
import sys
import urllib.error
import urllib.request

SUPABASE_URL = os.environ['SUPABASE_URL'].rstrip('/')
SERVICE_KEY = os.environ['SUPABASE_SERVICE_ROLE_KEY']

SOURCE_TAG = 'nomadwise-webflow'


def req(url, method='GET', body=None, prefer=None):
    headers = {
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json',
    }
    if prefer:
        headers['Prefer'] = prefer
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(
            urllib.request.Request(url, data=data, method=method,
                                   headers=headers)) as resp:
        txt = resp.read().decode()
        return json.loads(txt) if txt else None


here = os.path.dirname(__file__)
listings = json.load(open(os.path.join(here, 'webflow_import_data.json')))

# ---- migration check: bail out politely if migration37 wasn't run ----
try:
    req(f'{SUPABASE_URL}/rest/v1/venues?select=source&limit=1')
except urllib.error.HTTPError:
    report = {'error': 'migration37 not run yet (venues.source missing) '
                       '— import skipped, nothing changed'}
    os.makedirs('ci-debug', exist_ok=True)
    with open('ci-debug/webflow_import_report.json', 'w') as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report, indent=2))
    sys.exit(0)

# ---- what does Nomadmaps already know? ----
venues = req(f'{SUPABASE_URL}/rest/v1/venues?select=google_place_id,source')
known = {v['google_place_id'] for v in venues if v.get('google_place_id')}
already_imported = sum(1 for v in venues
                       if v.get('source') == SOURCE_TAG)

discovered = set()
offset = 0
while True:
    page = req(f'{SUPABASE_URL}/rest/v1/discovered_places'
               f'?select=google_place_id&limit=1000&offset={offset}')
    discovered.update(d['google_place_id'] for d in page)
    if len(page) < 1000:
        break
    offset += 1000

# ---- pick the newcomers ----
rows, skipped_existing, skipped_no_pid = [], 0, 0
for l in listings:
    pid = l.get('place_id')
    if not pid:
        skipped_no_pid += 1
        continue
    if pid in known or pid in discovered:
        skipped_existing += 1
        continue
    known.add(pid)  # guard against duplicate pids inside the export
    rows.append({
        'name': l['name'],
        'type': l['type'],
        'city': '',                       # enrichment fills the real city
        'neighbourhood': l.get('neighbourhood'),
        'google_place_id': pid,
        'lat': l.get('lat'),
        'lng': l.get('lng'),
        'laptops_allowed': True,          # curated work spots by definition
        'wifi_speed_mbps': l.get('wifi'),
        'power_outlets': l.get('power_outlets'),
        'aircon': l.get('aircon'),
        'comfortable_seating': l.get('comfortable_seating'),
        'cozy': l.get('cozy'),
        'quiet_space': l.get('quiet_space'),
        'good_for_calls': l.get('good_for_calls'),
        'call_room': l.get('call_room'),
        'monitor': l.get('monitor'),
        'office_chairs': l.get('office_chairs'),
        'access_24h': l.get('access_24h'),
        'website': l.get('website'),
        'instagram': l.get('instagram'),
        'google_rating_snapshot': l.get('rating'),
        'google_reviews_snapshot': l.get('reviews'),
        'opening_hours': l.get('hours'),
        'webflow_cms_id': l['webflow_id'],
        'status': 'verified',
        'source': SOURCE_TAG,
    })

inserted = 0
error = None
try:
    for i in range(0, len(rows), 200):
        chunk = rows[i:i + 200]
        resp = req(f'{SUPABASE_URL}/rest/v1/venues'
                   '?on_conflict=google_place_id&select=id',
                   method='POST', body=chunk,
                   prefer='resolution=ignore-duplicates,'
                          'return=representation')
        inserted += len(resp or [])
except urllib.error.HTTPError as e:
    detail = e.read().decode()[:300]
    if 'source' in detail and ('column' in detail or 'schema' in detail):
        error = 'migration37 not run yet (venues.source missing) — skipped'
    else:
        error = f'HTTP {e.code}: {detail}'

report = {
    'listings_in_export': len(listings),
    'already_imported_before_run': already_imported,
    'inserted_this_run': inserted,
    'skipped_already_in_nomadmaps': skipped_existing,
    'skipped_no_place_id': skipped_no_pid,
    'error': error,
}
os.makedirs('ci-debug', exist_ok=True)
with open('ci-debug/webflow_import_report.json', 'w') as fh:
    json.dump(report, fh, indent=2)
print(json.dumps(report, indent=2))
if error:
    sys.exit(0)  # never fail the build over the import
