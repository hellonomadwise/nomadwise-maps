#!/usr/bin/env python3
"""One-off enrichment: fill venue coordinates (and missing Place IDs)
from the Google Places API, writing them back to Supabase.

Runs in GitHub Actions (workflow: enrich.yml). Needs env vars:
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, GOOGLE_PLACES_KEY
"""
import json
import os
import urllib.request

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
