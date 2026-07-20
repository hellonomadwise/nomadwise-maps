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
SIGNALS_PER_RUN = 150

try:
    unchecked = req(
        f'{SUPABASE_URL}/rest/v1/discovered_places'
        '?select=google_place_id,name'
        '&signals_checked_at=is.null'
        f'&limit={SIGNALS_PER_RUN}',
        headers=sb_headers())
except Exception as e:  # noqa: BLE001
    unchecked = []
    print(f'Signals phase skipped (migration 29 not run yet?): {e}')

import urllib.error  # noqa: E402

checked, promising = 0, 0
for p in unchecked:
    counts = {'wifi': 0, 'power': 0, 'laptop': 0}
    try:
        details = req(
            f"https://places.googleapis.com/v1/places/{p['google_place_id']}",
            headers={
                'X-Goog-Api-Key': PLACES_KEY,
                'X-Goog-FieldMask': 'reviews',
            })
        for rv in (details or {}).get('reviews') or []:
            text = ((rv.get('text') or {}).get('text') or '').lower()
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
                'signals_checked_at':
                    datetime.now(timezone.utc).isoformat(),
            })
        checked += 1
        if any(counts.values()):
            promising += 1
    except Exception:  # noqa: BLE001
        pass

print(f'Signals: {checked} places checked, {promising} promising.')
