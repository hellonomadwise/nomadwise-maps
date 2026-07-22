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
import math
import os
import re
import sys
import urllib.error
import urllib.request

SUPABASE_URL = os.environ['SUPABASE_URL'].rstrip('/')
SERVICE_KEY = os.environ['SUPABASE_SERVICE_ROLE_KEY']
PLACES_KEY = os.environ.get('GOOGLE_PLACES_KEY', '')

SOURCE_TAG = 'nomadwise-webflow'

# Listings whose Webflow map links carry no Google Place ID are resolved
# by searching Google for the name near the listing's own coordinates.
# A match is only accepted when it is BOTH nearby and similarly named.
MAX_MATCH_DISTANCE_M = 400
RESOLVE_PER_RUN = 350


def _norm(s):
    return re.sub(r'[^a-z0-9 ]', '', (s or '').lower()).strip()


def _names_agree(a, b):
    na, nb = _norm(a), _norm(b)
    if not na or not nb:
        return False
    if na in nb or nb in na:
        return True
    ta, tb = set(na.split()), set(nb.split())
    common = ta & tb
    return len(common) >= max(1, min(len(ta), len(tb)) // 2 + 1)


def _dist_m(lat1, lng1, lat2, lng2):
    rad = math.pi / 180
    dlat = (lat2 - lat1) * rad
    dlng = (lng2 - lng1) * rad
    a = (math.sin(dlat / 2) ** 2 +
         math.cos(lat1 * rad) * math.cos(lat2 * rad) *
         math.sin(dlng / 2) ** 2)
    return 6371000 * 2 * math.asin(math.sqrt(a))


def find_place(name, lat, lng):
    """Text-search Google for `name` near (lat, lng); return
    (place_id, distance_m, google_name) or None."""
    body = {
        'textQuery': name,
        'locationBias': {'circle': {
            'center': {'latitude': lat, 'longitude': lng},
            'radius': 1000.0,
        }},
        'maxResultCount': 3,
    }
    data = json.dumps(body).encode()
    r = urllib.request.Request(
        'https://places.googleapis.com/v1/places:searchText',
        data=data, method='POST',
        headers={
            'X-Goog-Api-Key': PLACES_KEY,
            'X-Goog-FieldMask':
                'places.id,places.location,places.displayName',
            'Content-Type': 'application/json',
        })
    with urllib.request.urlopen(r) as resp:
        found = json.loads(resp.read().decode())
    for p in found.get('places') or []:
        loc = p.get('location') or {}
        if loc.get('latitude') is None:
            continue
        d = _dist_m(lat, lng, loc['latitude'], loc['longitude'])
        gname = ((p.get('displayName') or {}).get('text')) or ''
        if d <= MAX_MATCH_DISTANCE_M and _names_agree(name, gname):
            return p['id'], round(d), gname
    return None


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
venues = req(f'{SUPABASE_URL}/rest/v1/venues'
             '?select=google_place_id,source,webflow_cms_id')
known = {v['google_place_id'] for v in venues if v.get('google_place_id')}
imported_wf_ids = {v['webflow_cms_id'] for v in venues
                   if v.get('webflow_cms_id')}
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
resolved, unresolved, searches = 0, [], 0
unresolved_rows = []
for l in listings:
    pid = l.get('place_id')
    if not pid:
        # Already imported on an earlier run via Google resolution?
        if l['webflow_id'] in imported_wf_ids:
            skipped_existing += 1
            continue
        # Try to identify the place on Google by name + coordinates.
        if (PLACES_KEY and l.get('lat') is not None
                and searches < RESOLVE_PER_RUN):
            searches += 1
            note = ''
            try:
                hit = find_place(l['name'], l['lat'], l['lng'])
            except Exception as e:  # noqa: BLE001
                hit = None
                note = f' (search error: {e})'
            if hit:
                pid, dist, gname = hit
                resolved += 1
                print(f"resolved: {l['name']} -> {gname} ({dist} m)")
            else:
                unresolved.append(l['name'] + note)
                unresolved_rows.append({
                    'name': l['name'], 'slug': l['slug'],
                    'lat': l.get('lat'), 'lng': l.get('lng'),
                    'note': note.strip() or 'no confident Google match',
                })
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
    'google_searches_this_run': searches,
    'resolved_via_google': resolved,
    'no_confident_match_count': len(unresolved),
    'no_confident_match_sample': unresolved[:40],
    'error': error,
}
os.makedirs('ci-debug', exist_ok=True)
with open('ci-debug/webflow_import_report.json', 'w') as fh:
    json.dump(report, fh, indent=2)
with open('ci-debug/webflow_unresolved.json', 'w') as fh:
    json.dump(unresolved_rows, fh, indent=2)
print(json.dumps(report, indent=2))
if error:
    sys.exit(0)  # never fail the build over the import
