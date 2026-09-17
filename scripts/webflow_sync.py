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

The reverse direction (the Website control centre in the app):
venues the founders set to website_status 'queued' are PREPARED each
night: the sync works out the slug, Region, Location, Country, hours
and facts and stores the proposal on the venue (website_prepared) for
the app's inbox. Nothing is created until a founder taps Approve
(website_approved_at); the next run then creates the Webflow item as
a DRAFT with the slug they saw, plus its Images entry. Nothing goes
live by itself: the founders add the photo and words in Webflow and
publish; the next night's pull sees the live page and marks the venue
'released'. A venue whose city matches no Webflow Region is prepared
with an error the app shows, with a dropdown to pick the Region
(website_region_override). The Regions collection is copied nightly
into webflow_regions for that dropdown.

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

# --push-only: skip the nightly pull and only prepare / create the
# queued spaces. Run every few minutes by webflow_push.yml so the
# control centre feels immediate; exits in a second when nothing is
# queued.
PUSH_ONLY = '--push-only' in sys.argv

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


if not PUSH_ONLY:
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


else:
    # Push-only run (every few minutes): no pull, no writes to venues.
    items = []
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()

# ------------------------------------------------------------- sitemap
# The custom sitemap is the truth about which released pages are in it.
# Read it nightly and keep venues.sitemap_added_at in step, so the
# control centre's Sitemap tab lists only pages that really are
# missing (and shows a page again if it ever drops out).
SITEMAP_URL = 'https://www.nomadwise.io/sitemap.xml'
import re  # noqa: E402

if not PUSH_ONLY:
    try:
        with urllib.request.urlopen(urllib.request.Request(
                SITEMAP_URL, headers={'User-Agent': 'nomadmaps-sync'}),
                timeout=60) as r:
            xml = r.read().decode('utf-8', 'replace')
        in_map = set(re.findall(
            r'<loc>\s*https?://(?:www\.)?nomadwise\.io/coworking/([^<\s]+?)\s*</loc>',
            xml))
        report['sitemap_entries'] = len(in_map)
        if in_map:
            released = sb_all('venues?website_status=eq.released'
                              '&webflow_slug=not.is.null'
                              '&select=id,webflow_slug,sitemap_added_at')
            mark = [v['id'] for v in released
                    if v['webflow_slug'] in in_map
                    and not v.get('sitemap_added_at')]
            unmark = [v['id'] for v in released
                      if v['webflow_slug'] not in in_map
                      and v.get('sitemap_added_at')]
            for i in range(0, len(mark), 100):
                ids = ','.join(mark[i:i + 100])
                sb(f'venues?id=in.({ids})', method='PATCH',
                   body={'sitemap_added_at': now}, prefer='return=minimal')
            for i in range(0, len(unmark), 100):
                ids = ','.join(unmark[i:i + 100])
                sb(f'venues?id=in.({ids})', method='PATCH',
                   body={'sitemap_added_at': None}, prefer='return=minimal')
            report['sitemap_marked'] = len(mark)
            report['sitemap_unmarked'] = len(unmark)
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'sitemap check: {e}')


# ---------------------------------------------------------------- push
# Venues the founders queued for the site become Webflow DRAFTS.

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
    """URL slug with accents folded (pa, not p, for 'på')."""
    x = unicodedata.normalize('NFKD', x or '')
    x = ''.join(c for c in x if not unicodedata.combining(c))
    x = (x.replace('ø', 'o').replace('Ø', 'o').replace('ß', 'ss')
          .replace('æ', 'ae').replace('Æ', 'ae').replace('œ', 'oe'))
    x = re.sub(r'[^a-z0-9]+', '-', x.lower()).strip('-')
    return re.sub(r'-{2,}', '-', x)


def word(flag, label):
    """App booleans back into Webflow's words. Unknown stays empty."""
    if flag is None:
        return None
    return label if flag else 'No'


MIN_PHOTOS = 3


def page_photos(v, limit=5):
    """The pictures for the page: the links the founder pasted, then
    approved community photos, five at most."""
    pasted = [str(u).strip() for u in (v.get('website_photos') or [])
              if str(u).strip().startswith('http')]
    out = list(dict.fromkeys(pasted))[:limit]
    if len(out) < limit:
        for u in approved_photos(v['id'], limit=limit):
            if u not in out:
                out.append(u)
            if len(out) >= limit:
                break
    return out


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


def plain_hours(text):
    """House style for opening hours: a plain hyphen with a space either
    side ('8:00 AM - 6:00 PM'). Google sends en dashes wrapped in narrow
    no-break spaces; those never reach Webflow."""
    t = str(text or '')
    t = re.sub('[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]', '-', t)
    t = re.sub('[\u00a0\u2009\u202f\u2007]', ' ', t)
    t = re.sub(r'\s*-\s*', ' - ', t)
    return re.sub(r'\s{2,}', ' ', t).strip()


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
                out[slug_] = plain_hours(h[k])
        return out
    g = v.get('g_details') or {}
    desc = ((g.get('regularOpeningHours') or {})
            .get('weekdayDescriptions') or [])
    for line, slug_ in zip(desc, slugs):
        if ':' in line:
            out[slug_] = plain_hours(line.split(':', 1)[1])
    return out


def region_rows(regions, country_by_id):
    """The Regions collection, flattened for the app's dropdown."""
    out = []
    for r in regions:
        if r.get('isArchived') or r.get('isDraft'):
            continue
        rf = r.get('fieldData') or {}
        c = country_by_id.get(rf.get('country')) or {}
        out.append({'id': r['id'],
                    'name': rf.get('name-label') or rf.get('name') or '',
                    'slug': rf.get('slug'),
                    'country': (c.get('fieldData') or {}).get('name'),
                    'updated_at': now})
    return out


def build_fields(v, region, loc, country, slug_, embed_key):
    """Every Webflow field a new listing gets from what the app knows."""
    rf, lf, cf = region['fieldData'], (loc['fieldData'] if loc else {}), \
        country['fieldData']
    is_cow = v.get('type') == 'coworking'
    kind = 'Coworking Space' if is_cow else 'Cafe'
    pid = v['google_place_id']
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
    where = lf.get('name-label') or rf.get('name-label')
    return fields, where, kind, cf.get('name')


def preview_of(v, fields, region, loc, country_name, kind, photos):
    """What the founder sees in the inbox before approving: plain
    words, no Webflow ids."""
    days = [('Monday', 'weekday-hours'), ('Tuesday', 'weekend-hours'),
            ('Wednesday', 'wednesday'), ('Thursday', 'thursday'),
            ('Friday', 'friday'), ('Saturday', 'saturday'),
            ('Sunday', 'sunday')]
    facts = [('Plug sockets', 'enough-plug-sockets'), ('Aircon', 'sea-view'),
             ('Comfortable seating', 'comfortable-seating'), ('Cozy', 'cozy'),
             ('Quiet space', 'gluten-friendly-option-gf'),
             ('Good for calls', 'good-for-calls'),
             ('Call room', 'isolated-quiet-room'),
             ('Monitor', 'monitor-available'),
             ('Office chairs', 'office-chairs'),
             ('24h access', '24hr-member-access')]
    return {
        'slug': fields['slug'],
        'url': f"https://www.nomadwise.io/coworking/{fields['slug']}",
        'region': region['fieldData'].get('name-label'),
        'region_id': region['id'],
        'location': (loc['fieldData'].get('name-label') if loc else None),
        'location_id': loc['id'] if loc else None,
        'location_chosen': bool(v.get('website_location_override')),
        'country': country_name,
        'kind': kind,
        'title_tag': fields.get('title-tag'),
        'h1': fields.get('h1-label'),
        'hours': {d: fields[k] for d, k in days if fields.get(k)},
        'facts': {lbl: ('No' if fields.get(k) == 'No' else 'Yes')
                  for lbl, k in facts if fields.get(k) is not None},
        'wifi_mbps': fields.get('average-internet-speed'),
        'rating': fields.get('rating'),
        'reviews': fields.get('reviews'),
        'website': fields.get('website-url'),
        'instagram': fields.get('instagram'),
        'photos': photos,
        'prepared_at': now,
    }


def save_prepared(v, prepared):
    try:
        sb(f"venues?id=eq.{v['id']}", method='PATCH',
           body={'website_prepared': prepared, 'website_prepared_at': now},
           prefer='return=minimal')
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f"prepare save {v['name']}: {e}")


try:
    queued = sb_all(
        'venues?website_status=eq.queued&webflow_cms_id=is.null'
        '&select=id,name,type,city,neighbourhood,google_place_id,lat,lng,'
        'website,instagram,wifi_speed_mbps,google_rating_snapshot,'
        'google_reviews_snapshot,opening_hours,g_details,power_outlets,'
        'aircon,comfortable_seating,cozy,quiet_space,good_for_calls,'
        'call_room,monitor,office_chairs,access_24h,'
        'website_approved_at,website_region_override,website_slug_override,'
        'website_location_override,website_prepared,country,website_photos,'
        'website_new_region,website_new_location')
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'queued read: {e}')
    queued = []
report['queued_for_site'] = len(queued)
report['prepared'] = []
report['awaiting_approval'] = []

if PUSH_ONLY and not queued:
    finish(0)   # nothing to do: the common case, a second of runtime

if PUSH_ONLY:
    # Existing slugs (uniqueness) and the Maps embed key come from the
    # collection itself; read it only when there is work to do.
    try:
        items = wf_all(f'/v2/collections/{COLLECTION_ID}/items')
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'webflow items: {e}')
        finish(1)

# The Webflow places are read every night, even with nothing queued,
# because the app's Region dropdown is a copy of them.
try:
    regions = wf_all(f'/v2/collections/{REGIONS_ID}/items')
    countries = wf_all(f'/v2/collections/{COUNTRIES_ID}/items')
    locations = wf_all(f'/v2/collections/{LOCATIONS_ID}/items')
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'webflow places read: {e}')
    locations, regions, countries = [], [], []
country_by_id = {c['id']: c for c in countries}

rows = region_rows(regions, country_by_id)
if rows and not PUSH_ONLY:
    try:
        sb('webflow_regions?on_conflict=id', method='POST', body=rows,
           prefer='resolution=merge-duplicates,return=minimal')
        report['regions_copied'] = len(rows)
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'regions copy: {e}')

loc_rows = []
for loc in locations:
    if loc.get('isArchived') or loc.get('isDraft'):
        continue
    lf = loc.get('fieldData') or {}
    c = country_by_id.get(lf.get('country')) or {}
    loc_rows.append({
        'id': loc['id'],
        'name': lf.get('name-label') or lf.get('name') or '',
        'slug': lf.get('slug'),
        'region_id': lf.get('region-3') or (lf.get('region-2') or [None])[0],
        'country': (c.get('fieldData') or {}).get('name'),
        'updated_at': now})
if loc_rows and not PUSH_ONLY:
    try:
        sb('webflow_locations?on_conflict=id', method='POST', body=loc_rows,
           prefer='resolution=merge-duplicates,return=minimal')
        report['locations_copied'] = len(loc_rows)
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'locations copy: {e}')

if queued:
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
        only have a Region); the Region is what a page needs. A Region
        the founder picked in the app wins over every guess."""
        loc_by_id = {loc['id']: loc for loc in locations}
        chosen_loc = v.get('website_location_override')
        chosen = v.get('website_region_override')
        # A Region or Location the founder asked for by name: use it the
        # moment it exists on the site (exact name), else wait.
        want_r = (v.get('website_new_region') or '').strip()
        if want_r and not chosen:
            hit = region_by_label.get(_norm(want_r))
            if hit:
                chosen = hit['id']
                sb(f"venues?id=eq.{v['id']}", method='PATCH',
                   body={'website_region_override': hit['id'],
                         'website_new_region': None},
                   prefer='return=minimal')
                report.setdefault('taxonomy_linked', []).append(
                    f"{v['name']}: Region {want_r}")
            else:
                return None, None
        want_l = (v.get('website_new_location') or '').strip()
        if want_l and not chosen_loc:
            hit = None
            for loc in locations:
                lf = loc.get('fieldData') or {}
                same_region = (not chosen) or chosen in (
                    lf.get('region-3'), *(lf.get('region-2') or []))
                if (not loc.get('isArchived') and not loc.get('isDraft')
                        and same_region
                        and _norm(lf.get('name-label')) == _norm(want_l)):
                    hit = loc
                    break
            if hit:
                chosen_loc = hit['id']
                sb(f"venues?id=eq.{v['id']}", method='PATCH',
                   body={'website_location_override': hit['id'],
                         'website_new_location': None},
                   prefer='return=minimal')
                report.setdefault('taxonomy_linked', []).append(
                    f"{v['name']}: Location {want_l}")
            else:
                return None, None
        # A Location the founder picked fixes both the Location and
        # (unless they also picked a Region) the Region it sits in.
        if chosen_loc and chosen_loc != 'none' and chosen_loc in loc_by_id:
            loc = loc_by_id[chosen_loc]
            lf = loc['fieldData']
            region = (region_by_id.get(chosen) if chosen else None) or \
                region_by_id.get(lf.get('region-3')) or \
                region_by_id.get((lf.get('region-2') or [None])[0])
            if region:
                return region, loc
        if chosen:
            region = (region_by_id.get(chosen) or
                      region_by_label.get(_norm(chosen)))
            if region:
                return region, None
        no_location = chosen_loc == 'none'
        # The app's own names first, then Google's English names
        # (the app may hold a local-language city like Kobenhavn).
        names = [v.get('neighbourhood'), v.get('city')]
        names += google_names(v.get('google_place_id'))
        names = [n for n in names if n]
        for cand in ([] if no_location else names):
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

    def country_of(v, country):
        """The country word for the slug: what the founder typed on the
        venue, else Google's address, else the Region's Country."""
        if v.get('country'):
            return v['country']
        for c in ((v.get('g_details') or {}).get('addressComponents') or []):
            if 'country' in (c.get('types') or []):
                return c.get('longText') or c.get('shortText')
        return (country.get('fieldData') or {}).get('name') or ''

    def pick_slug(v, region, country, prepared):
        """Always country-region-name (portugal-lisbon-lacs-anjos). The
        slug the founder saw or typed is used exactly, or not at all:
        if it turns out to be taken, None comes back and the space is
        flagged rather than quietly renamed. Only a fresh proposal
        (nothing seen yet) gets a -2 added to be unique."""
        prefix = f"{slugify(country_of(v, country))}-"
        typed = slugify(v.get('website_slug_override') or '')
        seen = (prepared or {}).get('slug')
        # A proposal made under the old rule (no country) is redone.
        fixed = typed or (seen if seen and seen.startswith(prefix) else None)
        if fixed:
            if fixed in taken_slugs:
                return None
            taken_slugs.add(fixed)
            return fixed
        base = (f"{prefix}{slugify(region['fieldData'].get('name-label'))}-"
                f"{slugify(v['name'])}")
        slug_ = base
        n = 2
        while slug_ in taken_slugs:
            slug_ = f'{base}-{n}'
            n += 1
        taken_slugs.add(slug_)
        return slug_

    def create_listing(v, fields, slug_, where):
        """The Webflow draft plus its Images entry; marks the venue."""
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
        photos = page_photos(v)
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

    for v in queued:
        old = v.get('website_prepared') or {}
        if not v.get('google_place_id'):
            save_prepared(v, {'error': 'no_place_id',
                              'why': 'Needs a Google match first'})
            report['needs_location'].append(
                {'name': v['name'], 'why': 'no Google Place ID'})
            continue
        region, loc = resolve_place(v)
        if not region and (v.get('website_new_region')
                           or v.get('website_new_location')):
            what = ('Region ' + v['website_new_region']
                    if v.get('website_new_region')
                    else 'Location ' + v['website_new_location'])
            save_prepared(v, {'error': 'awaiting_taxonomy',
                              'why': f'Waiting for {what} to be created in '
                                     'Webflow. Once it exists with that '
                                     'exact name, the space is linked to '
                                     'it automatically.'})
            report['needs_location'].append(
                {'name': v['name'], 'why': f'awaiting {what}'})
            continue
        if not region:
            names = google_names(v.get('google_place_id'))
            save_prepared(v, {'error': 'needs_region',
                              'city': v.get('city'),
                              'neighbourhood': v.get('neighbourhood'),
                              'google_names': names,
                              'why': 'No Region on nomadwise.io matches '
                                     'this city. Pick one in the app.'})
            report['needs_location'].append(
                {'name': v['name'], 'city': v.get('city'),
                 'neighbourhood': v.get('neighbourhood'),
                 'google_names': names,
                 'why': 'no Webflow Region or Location matches its '
                        'city or neighbourhood'})
            continue
        rf = region['fieldData']
        lf = loc['fieldData'] if loc else {}
        country = country_by_id.get(rf.get('country') or lf.get('country'))
        if not country:
            save_prepared(v, {'error': 'no_country',
                              'why': f"Region {rf.get('name')} has no "
                                     'Country in Webflow'})
            report['needs_location'].append(
                {'name': v['name'], 'region': rf.get('name'),
                 'why': 'Region has no Country'})
            continue

        slug_ = pick_slug(v, region, country,
                          old if not old.get('error') else None)
        if slug_ is None:
            wanted = (slugify(v.get('website_slug_override') or '')
                      or old.get('slug'))
            save_prepared(v, {'error': 'slug_taken', 'slug': wanted,
                              'region': rf.get('name-label'),
                              'region_id': region['id'],
                              'why': f'The slug "{wanted}" is already used '
                                     'by another listing. Choose a '
                                     'different one.'})
            report['needs_location'].append(
                {'name': v['name'], 'why': f'slug taken: {wanted}'})
            continue
        fields, where, kind, country_name = build_fields(
            v, region, loc, country, slug_, embed_key)
        photos = page_photos(v)
        prepared = preview_of(v, fields, region, loc, country_name, kind,
                              len(photos))
        prepared['photo_urls'] = photos

        if v.get('website_approved_at'):
            # Approved in the app: what the founder saw is what is
            # made (fresh facts, the same slug and place). Never
            # without a Country and Region: the slug is built from the
            # Region and cannot be changed afterwards.
            if not (region and country and fields.get('region-2')
                    and fields.get('country')):
                report['errors'].append(
                    f"refused {v['name']}: no Region or Country")
                continue
            if len(photos) < MIN_PHOTOS:
                save_prepared(v, dict(prepared, error='needs_photos',
                                      why=f'Only {len(photos)} picture(s). '
                                          f'At least {MIN_PHOTOS} are '
                                          'needed before the page is '
                                          'created.'))
                report['needs_location'].append(
                    {'name': v['name'], 'why': 'fewer than 3 photos'})
                continue
            try:
                create_listing(v, fields, slug_, where)
            except urllib.error.HTTPError as e:
                report['errors'].append(
                    f"create {v['name']}: {e.code} {e.read().decode()[:300]}")
                save_prepared(v, dict(prepared, error='create_failed',
                                      why=f'Webflow said {e.code}'))
            except Exception as e:  # noqa: BLE001
                report['errors'].append(f"create {v['name']}: {e}")
                save_prepared(v, dict(prepared, error='create_failed',
                                      why=str(e)[:200]))
            time.sleep(1.1)  # stay well under Webflow's per-minute limit
        else:
            save_prepared(v, prepared)
            report['prepared'].append({'name': v['name'], 'slug': slug_,
                                       'region': prepared['region']})
            report['awaiting_approval'].append(v['name'])

report['no_place_id'] = report['no_place_id'][:20]
report['inserted_names'] = report['inserted_names'][:40]
finish(1 if report['errors'] else 0)
