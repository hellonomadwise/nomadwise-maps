#!/usr/bin/env python3
"""Nightly sync: the live nomadwise.io Webflow collection -> Nomadmaps venues.

Replaces webflow_import.py (which read a static export and only ever
inserted). This reads the Coworking collection straight from Webflow,
matches every listing to a venue by Google Place ID (the shared key,
stored in Webflow's "Google Place ID" field), and keeps the venue's
website link and editorial facts current. It never writes to Webflow.

What it writes, per matched venue:
  * webflow_cms_id, webflow_slug, website_status, website_synced_at
  * fields Webflow owns (words): name, type, website, instagram,
    neighbourhood, Google rating/review snapshots, fallback opening
    hours, the yes/no work-friendliness facts
  * wifi_speed_mbps only while no nomad has run a WiFi test there
    (measurements belong to the community, words belong to Webflow)

website_status (migration 49):
  released          live page that is in the sitemap
  published_hidden  live page kept out of the sitemap
  removed           archived, draft, or no live page
Venues previously imported from Webflow whose item has vanished are
marked removed but kept.

Listings whose place is unknown to Nomadmaps are inserted (source
'nomadwise-webflow', status 'verified'), exactly as the old import did.

Needs: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, WEBFLOW_API_TOKEN
(site token, CMS read + Sites read). Exits politely if any is missing
or migration 49 has not been applied yet.

Output: ci-debug/webflow_sync_report.json
"""
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
WEBFLOW_TOKEN = os.environ.get('WEBFLOW_API_TOKEN', '')

WEBFLOW_API = 'https://api.webflow.com'
COLLECTION_ID = '65fa86d0e0379bf78d52448d'
OPTION_CAFE = '7fabb5c16a682af1c6095714a143d04d'
OPTION_COWORKING = '6b3ea2850aad41efc9f6171025e9a810'
SOURCE_TAG = 'nomadwise-webflow'
PAGE = 100

here = os.path.dirname(os.path.abspath(__file__))
SNAPSHOT = os.path.join(here, 'webflow_sitemap_snapshot.json')

report = {
    'started': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'items_read': 0,
    'live_items': 0,
    'sitemap_source': None,
    'matched_by_place_id': 0,
    'matched_by_cms_id': 0,
    'inserted': 0,
    'updated': 0,
    'marked_removed': 0,
    'status_counts': {},
    'no_place_id': [],
    'skipped_not_live_new': 0,
    'errors': [],
}


def finish(code=0):
    report['finished'] = datetime.datetime.now(
        datetime.timezone.utc).isoformat()
    os.makedirs('ci-debug', exist_ok=True)
    with open('ci-debug/webflow_sync_report.json', 'w') as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report, indent=2))
    sys.exit(code)


if not (SUPABASE_URL and SERVICE_KEY and WEBFLOW_TOKEN):
    report['errors'].append(
        'missing SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY or '
        'WEBFLOW_API_TOKEN; nothing changed')
    finish(0)


# ---------------------------------------------------------------- http
def _call(url, headers, method='GET', body=None, retries=3):
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    url, data=data, method=method, headers=headers)) as r:
                txt = r.read().decode()
                return json.loads(txt) if txt else None
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries - 1:
                time.sleep(int(e.headers.get('Retry-After', '15')) + 1)
                continue
            raise


def wf(path, params=None):
    url = WEBFLOW_API + path
    if params:
        url += '?' + urllib.parse.urlencode(params)
    return _call(url, {
        'Authorization': f'Bearer {WEBFLOW_TOKEN}',
        'accept': 'application/json',
    })


def wf_all(path, params=None):
    """Page through a Webflow list endpoint (items + pagination)."""
    out, offset = [], 0
    while True:
        p = dict(params or {})
        p.update({'limit': PAGE, 'offset': offset})
        page = wf(path, p) or {}
        items = page.get('items') or []
        out.extend(items)
        total = (page.get('pagination') or {}).get('total')
        offset += len(items)
        if not items or (total is not None and offset >= total):
            break
        time.sleep(0.3)  # 60 requests/minute is the ceiling
    return out


def sb(path, method='GET', body=None, prefer=None):
    headers = {
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json',
    }
    if prefer:
        headers['Prefer'] = prefer
    return _call(f'{SUPABASE_URL}/rest/v1/{path}', headers, method, body)


def sb_all(path):
    out, offset = [], 0
    while True:
        sep = '&' if '?' in path else '?'
        page = sb(f'{path}{sep}limit=1000&offset={offset}') or []
        out.extend(page)
        if len(page) < 1000:
            return out
        offset += 1000


# ---------------------------------------------------------- field maps
def yes(v):
    """Webflow stores facts as words: 'Aircon' / 'Yes' mean true,
    'no' / 'No' / empty mean false, missing means unknown."""
    if v is None:
        return None
    s = str(v).strip().lower()
    if s in ('', 'no', 'false', 'n/a', 'none', '-'):
        return False
    return True


def hours_of(f):
    days = [('mon', 'weekday-hours'), ('tue', 'weekend-hours'),
            ('wed', 'wednesday'), ('thu', 'thursday'),
            ('fri', 'friday'), ('sat', 'saturday'), ('sun', 'sunday')]
    h = {k: (f.get(slug) or '').strip() for k, slug in days}
    h = {k: v for k, v in h.items() if v}
    return h or None


def venue_type(f, fallback=None):
    opt = f.get('cafe-or-coworking')
    if opt == OPTION_CAFE:
        return 'cafe'
    if opt == OPTION_COWORKING:
        return 'coworking'
    return fallback


def num(v):
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def editorial_fields(f, existing_type=None):
    """The columns Webflow owns. Only keys with a value are returned,
    so an empty Webflow field never blanks a venue."""
    out = {
        'name': (f.get('name') or '').strip() or None,
        'type': venue_type(f, existing_type),
        'website': (f.get('website-url') or '').strip() or None,
        'instagram': (f.get('instagram') or '').strip() or None,
        'neighbourhood': (f.get('locations-label') or '').strip() or None,
        'google_rating_snapshot': num(f.get('rating')),
        'google_reviews_snapshot': (int(f['reviews'])
                                    if f.get('reviews') is not None
                                    else None),
        'opening_hours': hours_of(f),
        'power_outlets': yes(f.get('enough-plug-sockets')),
        'aircon': yes(f.get('sea-view')),
        'comfortable_seating': yes(f.get('comfortable-seating')),
        'cozy': yes(f.get('cozy')),
        'quiet_space': yes(f.get('gluten-friendly-option-gf')),
        'good_for_calls': yes(f.get('good-for-calls')),
        'call_room': yes(f.get('isolated-quiet-room')),
        'monitor': yes(f.get('monitor-available')),
        'office_chairs': yes(f.get('office-chairs')),
        'access_24h': yes(f.get('24hr-member-access')),
    }
    return {k: v for k, v in out.items() if v is not None}


def _unexpected(exc_type, exc, tb):
    import traceback
    report['errors'].append('unexpected: ' + ''.join(
        traceback.format_exception(exc_type, exc, tb))[-800:])
    finish(1)


sys.excepthook = _unexpected


# ------------------------------------------------------------ webflow
try:
    items = wf_all(f'/v2/collections/{COLLECTION_ID}/items')
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'webflow items: {e}')
    finish(1)
report['items_read'] = len(items)

# Which items have a live page? The live endpoint lists only those.
try:
    live_items = wf_all(f'/v2/collections/{COLLECTION_ID}/items/live')
    live_ids = {i['id'] for i in live_items}
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'webflow live items: {e}')
    live_ids = {i['id'] for i in items
                if i.get('lastPublished') and not i.get('isArchived')
                and not i.get('isDraft')}
report['live_items'] = len(live_ids)

# Sitemap flag (the release switch). The beta endpoint path has moved
# before, so try the known spellings, then fall back to the snapshot
# committed with the repo, then to "every live page is released".
sitemap = None
for path in (f'/v2/beta/collections/{COLLECTION_ID}/items/sitemap',
             f'/beta/collections/{COLLECTION_ID}/items/sitemap'):
    try:
        rows = wf_all(path, {'type': 'live'})
        sitemap = {r['id']: bool(r.get('includeInSitemap'))
                   for r in rows if r.get('id')}
        report['sitemap_source'] = path
        break
    except Exception:  # noqa: BLE001
        continue
if sitemap is None and os.path.exists(SNAPSHOT):
    snap = json.load(open(SNAPSHOT))
    sitemap = {k: bool(v.get('includeInSitemap'))
               for k, v in (snap.get('items') or {}).items()}
    report['sitemap_source'] = 'snapshot ' + str(snap.get('generated'))
if sitemap is None:
    sitemap = {}
    report['sitemap_source'] = 'none (all live pages treated as released)'


def status_of(item):
    if item.get('isArchived') or item.get('isDraft'):
        return 'removed'
    if item['id'] not in live_ids:
        return 'removed'
    return 'released' if sitemap.get(item['id'], True) else 'published_hidden'


# ----------------------------------------------------------- supabase
try:
    venues = sb_all('venues?select=id,name,type,google_place_id,'
                    'webflow_cms_id,webflow_slug,website_status,source,'
                    'wifi_speed_mbps')
except urllib.error.HTTPError as e:
    detail = e.read().decode()[:300]
    report['errors'].append(
        'venues read failed (migration 49 not applied yet?): ' + detail)
    finish(0)

by_pid = {v['google_place_id']: v for v in venues if v.get('google_place_id')}
by_cms = {v['webflow_cms_id']: v for v in venues if v.get('webflow_cms_id')}

tested = set()
try:
    for s in sb_all('submissions?select=venue_id&kind=eq.wifi_test'
                    '&status=eq.verified'):
        if s.get('venue_id'):
            tested.add(s['venue_id'])
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'wifi tests read: {e}')

discovered = set()
try:
    for d in sb_all('discovered_places?select=google_place_id'):
        discovered.add(d['google_place_id'])
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'discovered read: {e}')

now = datetime.datetime.now(datetime.timezone.utc).isoformat()
updates, inserts = [], []
seen_cms = set()
claimed = set()   # a venue is written once even if two items point at it

for item in items:
    f = item.get('fieldData') or {}
    cms_id = item['id']
    seen_cms.add(cms_id)
    pid = (f.get('google-place-id') or '').strip() or None
    slug = (f.get('slug') or '').strip() or None
    status = status_of(item)

    venue, how = None, None
    if pid and pid in by_pid:
        venue, how = by_pid[pid], 'matched_by_place_id'
    elif cms_id in by_cms:
        venue, how = by_cms[cms_id], 'matched_by_cms_id'

    if venue and (venue.get('id') is None or venue['id'] in claimed):
        # Already handled this run (a second Webflow item pointing at
        # the same place, or a place queued for insertion just above).
        continue
    if venue:
        claimed.add(venue['id'])
        report[how] += 1
        row = {'id': venue['id'],
               'name': venue['name'], 'type': venue['type'],
               'webflow_cms_id': cms_id,
               'webflow_slug': slug,
               'website_status': status,
               'website_synced_at': now}
        row.update(editorial_fields(f, venue['type']))
        wifi = num(f.get('average-internet-speed'))
        if venue['id'] not in tested and wifi and wifi > 0:
            row['wifi_speed_mbps'] = wifi
        updates.append(row)
        report['status_counts'][status] = \
            report['status_counts'].get(status, 0) + 1
        continue

    # No venue yet.
    if not pid:
        report['no_place_id'].append(f.get('name'))
        continue
    if status == 'removed':
        report['skipped_not_live_new'] += 1
        continue
    if pid in discovered:
        # Known as a candidate; the screening flow promotes it. Leave.
        continue
    row = {
        'name': f.get('name'),
        'type': venue_type(f, 'cafe'),
        'city': '',
        'google_place_id': pid,
        'laptops_allowed': True,
        'webflow_cms_id': cms_id,
        'webflow_slug': slug,
        'website_status': status,
        'website_synced_at': now,
        'status': 'verified',
        'source': SOURCE_TAG,
    }
    row.update(editorial_fields(f))
    wifi = num(f.get('average-internet-speed'))
    if wifi and wifi > 0:
        row['wifi_speed_mbps'] = wifi
    inserts.append(row)
    by_pid[pid] = row
    report['status_counts'][status] = \
        report['status_counts'].get(status, 0) + 1

# Previously imported venues whose Webflow item is gone entirely.
gone = [v for v in venues
        if v.get('webflow_cms_id') and v['webflow_cms_id'] not in seen_cms
        and v.get('website_status') != 'removed']

# ------------------------------------------------------------- writes
try:
    for i in range(0, len(updates), 200):
        sb('venues?on_conflict=id', method='POST', body=updates[i:i + 200],
           prefer='resolution=merge-duplicates,return=minimal')
        report['updated'] += len(updates[i:i + 200])
    for i in range(0, len(inserts), 200):
        got = sb('venues?on_conflict=google_place_id&select=id',
                 method='POST', body=inserts[i:i + 200],
                 prefer='resolution=ignore-duplicates,'
                        'return=representation')
        report['inserted'] += len(got or [])
    for v in gone:
        sb(f"venues?id=eq.{v['id']}", method='PATCH',
           body={'website_status': 'removed', 'website_synced_at': now},
           prefer='return=minimal')
        report['marked_removed'] += 1
except urllib.error.HTTPError as e:
    report['errors'].append('write failed: ' + e.read().decode()[:400])
    finish(1)

report['no_place_id'] = report['no_place_id'][:20]
finish(0)
