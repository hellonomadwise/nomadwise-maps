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

The reverse direction (phase 0b): venues the founders have set to
website_status 'queued' in the admin screen get a Webflow item created
as a DRAFT, attached to the matching Country, Region and Location, with
every fact the app knows. Nothing goes live by itself: the founders
open the draft in Webflow, add the photo and words, and publish; the
next night's pull sees the live page and marks the venue 'released'.
A venue whose city or neighbourhood matches no Webflow Location is
left queued and listed under needs_location in the report.

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
PLACES_KEY = os.environ.get('GOOGLE_PLACES_KEY', '')

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
    'inserted_names': [],
    'skipped_not_live_new': 0,
    'queued_for_site': 0,
    'created_on_site': [],
    'needs_location': [],
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


EDITORIAL_KEYS = [
    'name', 'type', 'website', 'instagram', 'neighbourhood',
    'google_rating_snapshot', 'google_reviews_snapshot', 'opening_hours',
    'power_outlets', 'aircon', 'comfortable_seating', 'cozy', 'quiet_space',
    'good_for_calls', 'call_room', 'monitor', 'office_chairs', 'access_24h',
    'wifi_speed_mbps',
]


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
    if item.get('isArchived'):
        return 'removed'
    if item.get('isDraft'):
        # A draft that has never been live is a page in the making;
        # a draft that used to be live has been taken down.
        return 'removed' if item.get('lastPublished') else 'published_hidden'
    if item['id'] not in live_ids:
        return 'removed'
    return 'released' if sitemap.get(item['id'], True) else 'published_hidden'


# ----------------------------------------------------------- supabase
try:
    venues = sb_all('venues?select=id,google_place_id,webflow_cms_id,'
                    'webflow_slug,website_status,source,'
                    + ','.join(EDITORIAL_KEYS))
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
        # Same key set for every row (the API insists), starting from
        # what the venue holds now so an empty Webflow field never
        # blanks anything.
        row = {k: venue.get(k) for k in EDITORIAL_KEYS}
        row.update({'id': venue['id'],
                    'webflow_cms_id': cms_id,
                    'webflow_slug': slug,
                    'website_status': status,
                    'website_synced_at': now})
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
    row = {k: None for k in EDITORIAL_KEYS}
    row.update({
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
    })
    row.update(editorial_fields(f))
    wifi = num(f.get('average-internet-speed'))
    if wifi and wifi > 0:
        row['wifi_speed_mbps'] = wifi
    inserts.append(row)
    report['inserted_names'].append(row['name'])
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


# ---------------------------------------------------------------- push
# Venues the founders queued for the site become Webflow DRAFTS.
import re  # noqa: E402

IMAGES_ID = '65fa86d0e0379bf78d52451b'
IMAGES_TYPE_COWORKING = 'ca9c2f49fd6b2b993833e8563871ff2a'
LOCATIONS_ID = '65fa86d0e0379bf78d52451c'
REGIONS_ID = '660a67b0318bdc118b67a3e5'
COUNTRIES_ID = '660a654b9f17e25bfb2500bd'
ADDED_BY_NOMADWISE = '65fa86d0e0379bf78d524789'
DESCRIPTION = ('Find cafes & coworking spaces for digital nomads with '
               'fast WiFi, affordable coffee, aircon, comfy seating, '
               'plugs, and quiet spots. | ')


import math  # noqa: E402
import unicodedata  # noqa: E402

# Local spellings Google may return even in English.
CITY_ALIASES = {
    'kobenhavn': 'copenhagen', 'wien': 'vienna', 'munchen': 'munich',
    'lisboa': 'lisbon', 'firenze': 'florence', 'roma': 'rome',
    'milano': 'milan', 'napoli': 'naples', 'torino': 'turin',
    'venezia': 'venice', 'praha': 'prague', 'warszawa': 'warsaw',
    'krakow': 'krakow', 'athina': 'athens', 'sevilla': 'seville',
    'koln': 'cologne', 'bruxelles': 'brussels', 'brussel': 'brussels',
    'antwerpen': 'antwerp', 'den haag': 'the hague', 'geneve': 'geneva',
    'zurich': 'zurich', 'goteborg': 'gothenburg', 'bucuresti': 'bucharest',
    'beograd': 'belgrade', 'kyiv': 'kyiv', 'ho chi minh city': 'saigon',
}


def _norm(x):
    x = unicodedata.normalize('NFKD', x or '')
    x = ''.join(c for c in x if not unicodedata.combining(c))
    x = x.replace('ø', 'o').replace('Ø', 'o').replace('ß', 'ss')
    x = re.sub(r'[^a-z0-9]+', ' ', x.lower()).strip()
    return CITY_ALIASES.get(x, x)


def _km(lat1, lng1, lat2, lng2):
    rad = math.pi / 180
    dlat, dlng = (lat2 - lat1) * rad, (lng2 - lng1) * rad
    a = (math.sin(dlat / 2) ** 2 + math.cos(lat1 * rad) *
         math.cos(lat2 * rad) * math.sin(dlng / 2) ** 2)
    return 6371 * 2 * math.asin(math.sqrt(a))


NEAREST_REGION_KM = 30


def slugify(x):
    x = re.sub(r'[^a-z0-9]+', '-', (x or '').lower()).strip('-')
    return re.sub(r'-{2,}', '-', x)


def word(flag, label):
    """App booleans back into Webflow's words. Unknown stays empty."""
    if flag is None:
        return None
    return label if flag else 'No'


def approved_photos(venue_id, limit=5):
    """Public URLs of the community photos an admin has approved,
    oldest first (Google's photos may not be copied to the site)."""
    try:
        rows = sb(f'venue_photos?venue_id=eq.{venue_id}'
                  f'&select=photo_path&order=verified_at.asc&limit={limit}')
    except Exception:  # noqa: BLE001
        return []
    return [f'{SUPABASE_URL}/storage/v1/object/public/submission-photos/'
            f"{r['photo_path']}" for r in (rows or []) if r.get('photo_path')]


def wf_write(path, method, body):
    return _call(WEBFLOW_API + path,
                 {'Authorization': f'Bearer {WEBFLOW_TOKEN}',
                  'accept': 'application/json',
                  'Content-Type': 'application/json'},
                 method=method, body=body)


def day_fields(v):
    """Monday..Sunday text from the venue's own hours, else from the
    cached Google details ('Monday: 9:00 AM - 5:00 PM')."""
    slugs = ['weekday-hours', 'weekend-hours', 'wednesday', 'thursday',
             'friday', 'saturday', 'sunday']
    keys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']
    out = {}
    h = v.get('opening_hours') or {}
    if h:
        for k, slug_ in zip(keys, slugs):
            if h.get(k):
                out[slug_] = h[k]
        return out
    g = v.get('g_details') or {}
    desc = ((g.get('regularOpeningHours') or {})
            .get('weekdayDescriptions') or [])
    for line, slug_ in zip(desc, slugs):
        if ':' in line:
            out[slug_] = line.split(':', 1)[1].strip()
    return out


try:
    queued = sb_all(
        'venues?website_status=eq.queued&webflow_cms_id=is.null'
        '&select=id,name,type,city,neighbourhood,google_place_id,lat,lng,'
        'website,'
        'instagram,wifi_speed_mbps,google_rating_snapshot,'
        'google_reviews_snapshot,opening_hours,g_details,power_outlets,'
        'aircon,comfortable_seating,cozy,quiet_space,good_for_calls,'
        'call_room,monitor,office_chairs,access_24h')
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'queued read: {e}')
    queued = []
report['queued_for_site'] = len(queued)

if queued:
    try:
        locations = wf_all(f'/v2/collections/{LOCATIONS_ID}/items')
        regions = wf_all(f'/v2/collections/{REGIONS_ID}/items')
        countries = wf_all(f'/v2/collections/{COUNTRIES_ID}/items')
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'webflow places read: {e}')
        locations, regions, countries = [], [], []

    loc_by_label = {}
    for loc in locations:
        if loc.get('isArchived') or loc.get('isDraft'):
            continue
        loc_by_label.setdefault(
            _norm(loc['fieldData'].get('name-label')), loc)
    region_by_id = {r['id']: r for r in regions}
    region_by_label = {}
    for r in regions:
        if not (r.get('isArchived') or r.get('isDraft')):
            region_by_label.setdefault(
                _norm(r['fieldData'].get('name-label')), r)
    country_by_id = {c['id']: c for c in countries}
    taken_slugs = {(i.get('fieldData') or {}).get('slug') for i in items}

    # The public Maps embed key the existing pages already use.
    embed_key = ''
    for i in items:
        m = re.search(r'[?&]key=([^&]+)', (i.get('fieldData') or {})
                      .get('map-embed') or '')
        if m:
            embed_key = m.group(1)
            break

    def google_names(pid):
        """English place names for a venue, most specific first:
        neighbourhood, district, town, county. Empty if no key."""
        if not (PLACES_KEY and pid):
            return []
        try:
            d = _call(f'https://places.googleapis.com/v1/places/{pid}'
                      '?languageCode=en',
                      {'X-Goog-Api-Key': PLACES_KEY,
                       'X-Goog-FieldMask': 'addressComponents'})
        except Exception:  # noqa: BLE001
            return []
        comps = (d or {}).get('addressComponents') or []
        order = ['neighborhood', 'sublocality_level_1', 'sublocality',
                 'locality', 'postal_town', 'administrative_area_level_2',
                 'administrative_area_level_1']
        out = []
        for wanted in order:
            for c in comps:
                if wanted in (c.get('types') or []):
                    for name in (c.get('longText'), c.get('shortText')):
                        if name and name not in out:
                            out.append(name)
        return out

    def resolve_place(v):
        """(region, location or None) for a venue. A Location is a
        neighbourhood inside a Region and is optional (many listings
        only have a Region); the Region is what a page needs."""
        # The app's own names first, then Google's English names
        # (the app may hold a local-language city like Kobenhavn).
        names = [v.get('neighbourhood'), v.get('city')]
        names += google_names(v.get('google_place_id'))
        names = [n for n in names if n]
        for cand in names:
            loc = loc_by_label.get(_norm(cand))
            if loc:
                lf = loc['fieldData']
                region = (region_by_id.get(lf.get('region-3')) or
                          region_by_id.get((lf.get('region-2') or [None])[0]))
                if region:
                    return region, loc
        for cand in names:
            region = region_by_label.get(_norm(cand))
            if region:
                return region, None
        # Names failed (a local spelling, say): the nearest Region on
        # the map wins, if it is close enough to be the same city.
        lat, lng = v.get('lat'), v.get('lng')
        if lat is not None and lng is not None:
            best, best_km = None, None
            for r in regions:
                rf = r['fieldData']
                if (r.get('isArchived') or r.get('isDraft') or
                        rf.get('latitude') is None or
                        rf.get('longitude') is None):
                    continue
                d = _km(lat, lng, rf['latitude'], rf['longitude'])
                if best is None or d < best_km:
                    best, best_km = r, d
            if best is not None and best_km <= NEAREST_REGION_KM:
                return best, None
        return None, None

    for v in queued:
        if not v.get('google_place_id'):
            report['needs_location'].append(
                {'name': v['name'], 'why': 'no Google Place ID'})
            continue
        region, loc = resolve_place(v)
        if not region:
            report['needs_location'].append(
                {'name': v['name'], 'city': v.get('city'),
                 'neighbourhood': v.get('neighbourhood'),
                 'google_names': google_names(v.get('google_place_id')),
                 'why': 'no Webflow Region or Location matches its '
                        'city or neighbourhood'})
            continue
        rf = region['fieldData']
        lf = loc['fieldData'] if loc else {}
        country = country_by_id.get(rf.get('country') or lf.get('country'))
        if not country:
            report['needs_location'].append(
                {'name': v['name'], 'region': rf.get('name'),
                 'why': 'Region has no Country'})
            continue
        cf = country['fieldData']
        where = lf.get('name-label') or rf.get('name-label')
        is_cow = v.get('type') == 'coworking'
        kind = 'Coworking Space' if is_cow else 'Cafe'
        pid = v['google_place_id']
        base = f"{rf.get('slug')}-{slugify(v['name'])}"
        slug_ = base
        n = 2
        while slug_ in taken_slugs:
            slug_ = f'{base}-{n}'
            n += 1
        taken_slugs.add(slug_)

        fields = {
            'name': v['name'],
            'slug': slug_,
            'google-place-id': pid,
            'cafe-or-coworking': OPTION_COWORKING if is_cow else OPTION_CAFE,
            'country': country['id'],
            'region-2': region['id'],
            'locations': loc['id'] if loc else None,
            'locations-label': lf.get('name-label'),
            'region-label': rf.get('name-label'),
            'place-added-by': ADDED_BY_NOMADWISE,
            'map-embed': ('https://www.google.com/maps/embed/v1/place'
                          f'?key={embed_key}&q=place_id:{pid}'),
            'map-directions': ('https://www.google.com/maps/search/?api=1'
                               f"&query={urllib.parse.quote(v['name'])}"
                               f'&query_place_id={pid}'),
            'website-url': v.get('website'),
            'instagram': v.get('instagram'),
            'rating': v.get('google_rating_snapshot'),
            'reviews': v.get('google_reviews_snapshot'),
            'average-internet-speed': v.get('wifi_speed_mbps'),
            'enough-plug-sockets': word(v.get('power_outlets'),
                                        'Enough Plug Sockets'),
            'sea-view': word(v.get('aircon'), 'Aircon'),
            'comfortable-seating': word(v.get('comfortable_seating'),
                                        'Comfortable Seating'),
            'cozy': word(v.get('cozy'), 'Cozy'),
            'gluten-friendly-option-gf': word(v.get('quiet_space'),
                                              'Quiet Space'),
            'good-for-calls': word(v.get('good_for_calls'), 'Good for Calls'),
            'isolated-quiet-room': word(v.get('call_room'), 'Skype Room'),
            'monitor-available': word(v.get('monitor'), 'Monitor Available'),
            'office-chairs': word(v.get('office_chairs'), 'Office Chairs'),
            '24hr-member-access': word(v.get('access_24h'), '24 Hour Access'),
            'membership-plans-available': 'Pass Required' if is_cow else 'No',
            'h1-label': (f"{v['name']} in {lf.get('name-label')} - "
                         f"{rf.get('name-label')}" if loc
                         else f"{v['name']} in {rf.get('name-label')}"),
            'title-tag': f"{v['name']}: {kind} with WiFi in "
                         f"{rf.get('name-label')}",
            'meta-description': DESCRIPTION + v['name'],
            'back-button-url': ('https://www.nomadwise.io/region/'
                                f"{rf.get('slug')}"),
            'nofollow': 'nofollow',
        }
        fields.update(day_fields(v))
        fields = {k: val for k, val in fields.items() if val is not None}
        try:
            made = wf_write(f'/v2/collections/{COLLECTION_ID}/items', 'POST',
                            {'isDraft': True, 'isArchived': False,
                             'fieldData': fields})
            new_id = (made or {}).get('id')
            if not new_id:
                raise RuntimeError(f'no id in response: {made}')

            # Its Images entry: the approved community photos, plus
            # the alt and title text the other entries use. Created
            # even when there are no photos yet, so the founders only
            # have to drop pictures in, not build the entry.
            photos = approved_photos(v['id'])
            caption = f"{v['name']} in {where}"
            img = {'name': f"{v['name']} 1", 'slug': f'{slug_}-1',
                   'coworking-space': new_id,
                   'coworking-spaces-multi-ref': [new_id],
                   'type': IMAGES_TYPE_COWORKING,
                   'has-enough-images': len(photos) > 3}
            for n, url in enumerate(photos, start=1):
                suffix = '' if n == 1 else f'-{n}'
                alt = caption if n == 1 else f'{caption} {n}'
                img[f'image{suffix}'] = {'url': url, 'alt': alt}
                img[f'alt-text{suffix}'] = alt
                img[f'image-title{suffix}'] = caption
            time.sleep(1.1)
            made_img = wf_write(f'/v2/collections/{IMAGES_ID}/items', 'POST',
                                {'isDraft': True, 'isArchived': False,
                                 'fieldData': img})
            img_id = (made_img or {}).get('id')
            if img_id:
                time.sleep(1.1)
                wf_write(f'/v2/collections/{COLLECTION_ID}/items/{new_id}',
                         'PATCH', {'fieldData': {'image-reference': img_id}})

            sb(f"venues?id=eq.{v['id']}", method='PATCH',
               body={'webflow_cms_id': new_id, 'webflow_slug': slug_,
                     'website_status': 'published_hidden',
                     'website_synced_at': now},
               prefer='return=minimal')
            report['created_on_site'].append(
                {'name': v['name'], 'slug': slug_, 'photos': len(photos),
                 'images_entry': bool(img_id)})
        except urllib.error.HTTPError as e:
            report['errors'].append(
                f"create {v['name']}: {e.code} {e.read().decode()[:300]}")
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f"create {v['name']}: {e}")
        time.sleep(1.1)  # stay well under Webflow's per-minute limit

report['no_place_id'] = report['no_place_id'][:20]
report['inserted_names'] = report['inserted_names'][:40]
finish(1 if report['errors'] else 0)
