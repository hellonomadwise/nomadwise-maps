#!/usr/bin/env python3
"""One-off enrichment: fill venue coordinates (and missing Place IDs)
from the Google Places API, writing them back to Supabase.

Runs in GitHub Actions (workflow: enrich.yml). Needs env vars:
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, GOOGLE_PLACES_KEY
"""
import json
import os
import urllib.request
from datetime import datetime, timedelta, timezone

SUPABASE_URL = os.environ['SUPABASE_URL'].rstrip('/')
SERVICE_KEY = os.environ['SUPABASE_SERVICE_ROLE_KEY']
PLACES_KEY = os.environ['GOOGLE_PLACES_KEY']


def req(url, method='GET', headers=None, body=None):
    r = urllib.request.Request(url, method=method, headers=headers or {})
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(
            urllib.request.Request(url, data=data, method=method,
                                   headers=headers or {})) as resp:
        txt = resp.read().decode()
        return json.loads(txt) if txt else None


def sb_headers(extra=None):
    h = {
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json',
    }
    if extra:
        h.update(extra)
    return h


def place_details(place_id):
    return req(
        f'https://places.googleapis.com/v1/places/{place_id}',
        headers={
            'X-Goog-Api-Key': PLACES_KEY,
            'X-Goog-FieldMask': 'location,displayName,addressComponents',
        })


def city_from(details):
    comps = (details or {}).get('addressComponents') or []
    for wanted in ('locality', 'postal_town', 'administrative_area_level_2'):
        for c in comps:
            if wanted in (c.get('types') or []):
                return c.get('longText') or c.get('shortText')
    return None


def text_search(query):
    return req(
        'https://places.googleapis.com/v1/places:searchText',
        method='POST',
        headers={
            'X-Goog-Api-Key': PLACES_KEY,
            'X-Goog-FieldMask':
                'places.id,places.location,places.displayName',
            'Content-Type': 'application/json',
        },
        body={'textQuery': query})


venues = req(
    f'{SUPABASE_URL}/rest/v1/venues'
    '?select=id,name,city,google_place_id,lat,lng',
    headers=sb_headers())

updated, failed = 0, []
for v in venues:
    needs_coords = v['lat'] is None or not v['google_place_id']
    needs_city = not v.get('city')
    if not needs_coords and not needs_city:
        continue
    patch = {}
    try:
        pid = v['google_place_id']
        if not pid:
            found = text_search(f"{v['name']}, {v.get('city') or 'Lisbon'}")
            places = found.get('places') or []
            if not places:
                failed.append(v['name'])
                continue
            pid = places[0]['id']
            patch['google_place_id'] = pid
            loc = places[0].get('location') or {}
            details = None
        else:
            details = place_details(pid)
            loc = (details or {}).get('location') or {}
        if needs_coords and loc:
            patch['lat'] = loc.get('latitude')
            patch['lng'] = loc.get('longitude')
        if needs_city:
            if details is None:
                details = place_details(pid)
            c = city_from(details)
            if c:
                patch['city'] = c
        if patch:
            req(f"{SUPABASE_URL}/rest/v1/venues?id=eq.{v['id']}",
                method='PATCH',
                headers=sb_headers({'Prefer': 'return=minimal'}),
                body=patch)
            updated += 1
            print(f"updated: {v['name']}")
    except Exception as e:  # noqa: BLE001
        failed.append(f"{v['name']} ({e})")

print(f"\nDone. {updated} venues updated.")
if failed:
    print("Needs a human look:", *failed, sep='\n  - ')


# ============================================================
# Phase 2: weekly Google snapshot per venue (rating, hours,
# photo list). The app reads this cached copy instead of calling
# Google itself, keeping Places API usage inside the free tier.
# ============================================================

SNAPSHOT_FIELDS = ','.join([
    'displayName', 'rating', 'userRatingCount',
    'currentOpeningHours', 'regularOpeningHours',
    'location', 'shortFormattedAddress', 'addressComponents',
    'photos',
])
MAX_AGE_DAYS = 7      # refresh each venue at most once a week
MAX_PER_RUN = 300     # hard cap per run, bounds worst-case API spend


def snapshot_details(place_id):
    return req(
        f'https://places.googleapis.com/v1/places/{place_id}',
        headers={
            'X-Goog-Api-Key': PLACES_KEY,
            'X-Goog-FieldMask': SNAPSHOT_FIELDS,
        })


def slim(details):
    """Keep only the fields the app actually reads. The raw response
    carries heavy extras (address breakdowns, photo author credits)
    that would otherwise be downloaded on every single app open."""
    if not details:
        return details
    out = {}
    for k in ('displayName', 'rating', 'userRatingCount',
              'currentOpeningHours', 'regularOpeningHours',
              'location', 'shortFormattedAddress'):
        if details.get(k) is not None:
            out[k] = details[k]
    photos = details.get('photos') or []
    if photos:
        out['photos'] = [{'name': p['name']}
                         for p in photos[:6] if p.get('name')]
    return out


try:
    rows = req(
        f'{SUPABASE_URL}/rest/v1/venues'
        '?select=id,name,google_place_id,g_synced_at'
        '&google_place_id=not.is.null',
        headers=sb_headers())
except Exception as e:  # noqa: BLE001
    rows = []
    print(f'Snapshot phase skipped (migration 24 not run yet?): {e}')

cutoff = datetime.now(timezone.utc) - timedelta(days=MAX_AGE_DAYS)
stale = []
for v in rows:
    ts = v.get('g_synced_at')
    if ts is None:
        stale.append(v)
        continue
    try:
        synced = datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except ValueError:
        stale.append(v)
        continue
    if synced < cutoff:
        stale.append(v)

snapped, snap_failed = 0, []
for v in stale[:MAX_PER_RUN]:
    try:
        details = snapshot_details(v['google_place_id'])
        if not details:
            snap_failed.append(v['name'])
            continue
        patch = {
            'g_details': slim(details),
            'g_synced_at': datetime.now(timezone.utc).isoformat(),
        }
        if details.get('rating') is not None:
            patch['google_rating_snapshot'] = details['rating']
        if details.get('userRatingCount') is not None:
            patch['google_reviews_snapshot'] = details['userRatingCount']
        req(f"{SUPABASE_URL}/rest/v1/venues?id=eq.{v['id']}",
            method='PATCH',
            headers=sb_headers({'Prefer': 'return=minimal'}),
            body=patch)
        snapped += 1
    except Exception as e:  # noqa: BLE001
        snap_failed.append(f"{v['name']} ({e})")

skipped = max(0, len(stale) - MAX_PER_RUN)
print(f'Snapshots: {snapped} refreshed, {len(rows) - len(stale)} fresh, '
      f'{skipped} deferred to next run.')
if snap_failed:
    print('Snapshot failures:', *snap_failed, sep='\n  - ')


# ------------------------------------------------------------
# Cleanup: slim any already-stored snapshots that still carry
# the heavy extras. Pure JSON rework — zero Google calls.
# ------------------------------------------------------------
try:
    full = req(
        f'{SUPABASE_URL}/rest/v1/venues'
        '?select=id,g_details&g_details=not.is.null',
        headers=sb_headers())
except Exception:  # noqa: BLE001
    full = []

slimmed = 0
for v in full:
    d = v.get('g_details') or {}
    bloated = ('addressComponents' in d
               or any(set(p.keys()) - {'name'}
                      for p in (d.get('photos') or [])))
    if not bloated:
        continue
    try:
        req(f"{SUPABASE_URL}/rest/v1/venues?id=eq.{v['id']}",
            method='PATCH',
            headers=sb_headers({'Prefer': 'return=minimal'}),
            body={'g_details': slim(d)})
        slimmed += 1
    except Exception:  # noqa: BLE001
        pass
if slimmed:
    print(f'Slimmed {slimmed} stored snapshots.')


# ============================================================
# Phase 3: nomad signals for discovered (unscreened) places.
# Reads each place's Google reviews ONCE and stores how often
# they mention wifi / plugs / laptops, so the map can highlight
# promising pins without any per-user Google calls.
# ============================================================

SIGNAL_WORDS = {
    'wifi': ['wifi', 'wi-fi', 'wlan', 'internet'],
    'power': ['plug', 'socket', 'outlet', 'steckdose', 'tomada',
              'enchufe'],
    'laptop': ['laptop', 'notebook', 'digital nomad', 'remote work',
               'work from', 'working from', 'arbeiten', 'trabalhar',
               'trabajar', 'study', 'studying'],
}
# Reviews that argue AGAINST working there. One of these disqualifies
# a place from "promising", whatever else its reviews mention.
NEGATIVE_PHRASES = [
    'no laptop', 'laptops not allowed', 'laptop not allowed',
    'laptops are not allowed', 'laptop free', 'laptop-free',
    'no computers', 'computers not allowed', 'no wifi', 'no wi-fi',
    'wifi doesn’t work', "wifi doesn't work", 'wifi does not work',
    'no working on laptop', 'not laptop friendly',
    'not a place to work', 'keine laptops', 'kein laptop',
    'kein wlan', 'sin wifi', 'sem wifi', 'pas de wifi',
]
SIGNALS_PER_RUN = 250

try:
    cutoff_30d = (datetime.now(timezone.utc)
                  - timedelta(days=30)).isoformat()
    unchecked = req(
        f'{SUPABASE_URL}/rest/v1/discovered_places'
        '?select=google_place_id,name'
        f'&or=(signals_checked_at.is.null,signals_checked_at.lt.{cutoff_30d})'
        '&order=signals_checked_at.asc.nullsfirst'
        f'&limit={SIGNALS_PER_RUN}',
        headers=sb_headers())
except Exception as e:  # noqa: BLE001
    unchecked = []
    print(f'Signals phase skipped (migration 29 not run yet?): {e}')

import urllib.error  # noqa: E402

checked, promising = 0, 0
for p in unchecked:
    counts = {'wifi': 0, 'power': 0, 'laptop': 0}
    negatives = 0
    try:
        details = req(
            f"https://places.googleapis.com/v1/places/{p['google_place_id']}",
            headers={
                'X-Goog-Api-Key': PLACES_KEY,
                'X-Goog-FieldMask': 'reviews,businessStatus',
            })
        if (details or {}).get('businessStatus') not in (None, 'OPERATIONAL'):
            # Permanently/temporarily closed: off the map entirely.
            req(f"{SUPABASE_URL}/rest/v1/discovered_places"
                f"?google_place_id=eq.{p['google_place_id']}",
                method='DELETE',
                headers=sb_headers({'Prefer': 'return=minimal'}))
            print(f"Signals: removed closed place {p['name']}.")
            continue
        for rv in (details or {}).get('reviews') or []:
            text = ((rv.get('text') or {}).get('text') or '').lower()
            text = text.replace('’', "'")
            if any(ph in text for ph in NEGATIVE_PHRASES):
                negatives += 1
                continue  # a warning review is not a positive signal
            for signal, words in SIGNAL_WORDS.items():
                if any(w in text for w in words):
                    counts[signal] += 1
    except urllib.error.HTTPError:
        pass  # place gone or no access: store zeros, do not retry
    except Exception:  # noqa: BLE001
        continue  # transient problem: leave unchecked for next run
    try:
        req(f"{SUPABASE_URL}/rest/v1/discovered_places"
            f"?google_place_id=eq.{p['google_place_id']}",
            method='PATCH',
            headers=sb_headers({'Prefer': 'return=minimal'}),
            body={
                'signal_wifi': counts['wifi'],
                'signal_power': counts['power'],
                'signal_laptop': counts['laptop'],
                'signal_negative': negatives,
                'signals_checked_at':
                    datetime.now(timezone.utc).isoformat(),
            })
        checked += 1
        if any(counts.values()) and negatives == 0:
            promising += 1
    except Exception:  # noqa: BLE001
        pass

print(f'Signals: {checked} places checked, {promising} promising.')


# ============================================================
# Phase 4: city sweeps. Proactively discovers every cafe and
# coworking space in queued cities (scripts/sweep_queue.txt),
# one city per run, so a city's map is alive before its first
# user ever searches. The signal scan classifies the finds on
# the following nights.
# ============================================================

import math  # noqa: E402

SWEEP_RADIUS_M = 6000     # covers a city centre + inner neighbourhoods
CAFE_CELL_M = 1100        # cafe search every ~1.1 km (800 m circles)
COWORK_CELL_M = 2600      # coworking is sparser, coarser grid is fine
MAX_SWEEP_CALLS = 260     # hard cap per run, bounds API spend

SEARCH_MASK = ('places.id,places.displayName,places.location,'
               'places.primaryType,places.rating,'
               'places.userRatingCount,places.businessStatus')

import re  # noqa: E402
COWORK_NAME = re.compile(
    r'cowork|co-work|co work|workspace|work ?space|work ?hub|wework',
    re.I)


def _open_for_business(pl):
    return pl.get('businessStatus') in (None, 'OPERATIONAL')


def _looks_like_coworking(pl):
    if pl.get('primaryType') == 'coworking_space':
        return True
    name = (pl.get('displayName') or {}).get('text') or ''
    return bool(COWORK_NAME.search(name))


def _search_nearby_cafes(lat, lng, radius):
    return req(
        'https://places.googleapis.com/v1/places:searchNearby',
        method='POST',
        headers={
            'X-Goog-Api-Key': PLACES_KEY,
            'X-Goog-FieldMask': SEARCH_MASK,
            'Content-Type': 'application/json',
        },
        body={
            'includedTypes': ['cafe', 'coffee_shop'],
            'maxResultCount': 20,
            'locationRestriction': {'circle': {
                'center': {'latitude': lat, 'longitude': lng},
                'radius': radius,
            }},
        })


def _search_coworking(lat, lng, radius):
    return req(
        'https://places.googleapis.com/v1/places:searchText',
        method='POST',
        headers={
            'X-Goog-Api-Key': PLACES_KEY,
            'X-Goog-FieldMask': SEARCH_MASK,
            'Content-Type': 'application/json',
        },
        body={
            'textQuery': 'coworking space',
            'maxResultCount': 20,
            'locationBias': {'circle': {
                'center': {'latitude': lat, 'longitude': lng},
                'radius': radius,
            }},
        })


def _grid(center_lat, center_lng, cell_m):
    """Points covering a SWEEP_RADIUS_M circle, cell_m apart."""
    pts = []
    lat_step = cell_m / 111320.0
    lng_step = cell_m / (111320.0 * math.cos(math.radians(center_lat)))
    steps = int(SWEEP_RADIUS_M / cell_m) + 1
    for iy in range(-steps, steps + 1):
        for ix in range(-steps, steps + 1):
            if math.hypot(ix * cell_m, iy * cell_m) > SWEEP_RADIUS_M:
                continue
            pts.append((center_lat + iy * lat_step,
                        center_lng + ix * lng_step))
    return pts


def _row_from_place(pl, cowork=False):
    loc = pl.get('location') or {}
    if not pl.get('id') or loc.get('latitude') is None:
        return None
    return {
        'google_place_id': pl['id'],
        'name': (pl.get('displayName') or {}).get('text') or 'Unnamed',
        'lat': loc['latitude'],
        'lng': loc['longitude'],
        'primary_type':
            pl.get('primaryType') or ('coworking_space' if cowork else None),
        'rating': pl.get('rating'),
        'user_rating_count': pl.get('userRatingCount'),
    }


def _sweep_city(city):
    center = None
    hit = text_search(city)
    for pl in (hit or {}).get('places') or []:
        loc = pl.get('location') or {}
        if loc.get('latitude') is not None:
            center = (loc['latitude'], loc['longitude'])
            break
    if center is None:
        print(f'Sweep: could not locate "{city}", skipping.')
        return
    calls = 0
    places = {}
    for (la, ln) in _grid(center[0], center[1], CAFE_CELL_M):
        if calls >= MAX_SWEEP_CALLS:
            break
        calls += 1
        try:
            res = _search_nearby_cafes(la, ln, 800)
            for pl in (res or {}).get('places') or []:
                if not _open_for_business(pl):
                    continue
                row = _row_from_place(pl)
                if row:
                    places[row['google_place_id']] = row
        except Exception:  # noqa: BLE001
            pass
    for (la, ln) in _grid(center[0], center[1], COWORK_CELL_M):
        if calls >= MAX_SWEEP_CALLS:
            break
        calls += 1
        try:
            res = _search_coworking(la, ln, 1800)
            for pl in (res or {}).get('places') or []:
                if not _open_for_business(pl):
                    continue
                if not _looks_like_coworking(pl):
                    continue  # Google pads with restaurants etc.
                row = _row_from_place(pl, cowork=True)
                if row:
                    places.setdefault(row['google_place_id'], row)
        except Exception:  # noqa: BLE001
            pass
    rows = list(places.values())
    for i in range(0, len(rows), 100):
        try:
            req(f'{SUPABASE_URL}/rest/v1/discovered_places'
                '?on_conflict=google_place_id',
                method='POST',
                headers=sb_headers({
                    'Prefer': 'resolution=ignore-duplicates,return=minimal'}),
                body=rows[i:i + 100])
        except Exception as e:  # noqa: BLE001
            print(f'Sweep upsert issue: {e}')
    req(f'{SUPABASE_URL}/rest/v1/city_sweeps',
        method='POST',
        headers=sb_headers({'Prefer': 'return=minimal'}),
        body={
            'city': city,
            'center_lat': center[0],
            'center_lng': center[1],
            'places_found': len(rows),
        })
    print(f'Sweep: {city} done. {len(rows)} places from {calls} searches.')


try:
    queued_rows = req(
        f'{SUPABASE_URL}/rest/v1/sweep_queue'
        '?select=city&order=requested_at.asc',
        headers=sb_headers())
    done_rows = req(
        f'{SUPABASE_URL}/rest/v1/city_sweeps?select=city',
        headers=sb_headers())
    done = {r['city'].lower() for r in done_rows}
    pending = [r['city'] for r in queued_rows
               if r['city'].lower() not in done]
    if pending:
        _sweep_city(pending[0])  # one city per run, bounds cost
    else:
        print('Sweep: queue fully swept.')
except Exception as e:  # noqa: BLE001
    print(f'Sweep phase skipped (migration 34 not run yet?): {e}')
