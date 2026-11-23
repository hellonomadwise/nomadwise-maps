#!/usr/bin/env python3
"""
Space counts on nomadwise.io's Countries and Regions (23 Nov 2026).

The Coworking Global page (/coworking-global) lists the most popular
cities and every country that has spaces, ordered by how many. Webflow
cannot count, so each Country and Region item has a "Spaces" number
field that this script keeps right: the spaces on a live page
(website_status released, not retired) in that Region, and for a
Country the sum of its Regions (by the Region's own Country reference
on the site, so a country has one name, the site's: migration 347).

A Country with spaces also gets its Coworking Switch turned on (never
off), since that switch hides the "none listed yet" block on its page.
Writes and publishes an item only when something changed; draft items
get the number but are not published. Runs inside the website push
(called from webflow_products.py, after the area pages), at most once
an hour. Needs SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
WEBFLOW_API_TOKEN. Last run and what changed: sync_settings
'webflow_counts'.
"""
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
WEBFLOW_TOKEN = os.environ.get('WEBFLOW_API_TOKEN', '')
WEBFLOW_API = 'https://api.webflow.com'
COUNTRIES_ID = '660a654b9f17e25bfb2500bd'
REGIONS_ID = '660a67b0318bdc118b67a3e5'
EVERY = datetime.timedelta(minutes=60)


def now():
    return datetime.datetime.now(datetime.timezone.utc)


def _call(url, headers, method='GET', body=None, retries=3):
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    url, data=data, method=method, headers=headers), timeout=40) as r:
                txt = r.read().decode()
                return json.loads(txt) if txt else None
        except urllib.error.HTTPError as err:
            if err.code == 429 and attempt < retries - 1:
                time.sleep(int(err.headers.get('Retry-After', '15')) + 1)
                continue
            try:
                detail = err.read().decode()[:300]
            except Exception:  # noqa: BLE001
                detail = ''
            raise RuntimeError(f'{err.code} {detail}'.strip()) from None


def wf(path, method='GET', body=None):
    h = {'Authorization': f'Bearer {WEBFLOW_TOKEN}', 'accept': 'application/json'}
    if body is not None:
        h['Content-Type'] = 'application/json'
    time.sleep(1.1)
    return _call(WEBFLOW_API + path, h, method, body)


def sb(path, method='GET', body=None, prefer=None):
    h = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
         'Content-Type': 'application/json'}
    if prefer:
        h['Prefer'] = prefer
    return _call(f'{SUPABASE_URL}/rest/v1/{path}', h, method, body)


def all_items(collection):
    out, offset = [], 0
    while True:
        page = wf(f'/v2/collections/{collection}/items?limit=100&offset={offset}') or {}
        items = page.get('items') or []
        out += items
        if len(items) < 100:
            return out
        offset += 100


def live_region_ids():
    out, offset = [], 0
    while True:
        rows = sb('venues?select=webflow_region_id&website_status=eq.released'
                  '&website_retired_at=is.null&webflow_slug=not.is.null'
                  f'&webflow_region_id=not.is.null&order=id&limit=1000&offset={offset}') or []
        out += [r['webflow_region_id'] for r in rows]
        if len(rows) < 1000:
            return out
        offset += 1000


def counts(region_ids, regions):
    per_region = {}
    for rid in region_ids:
        per_region[rid] = per_region.get(rid, 0) + 1
    per_country = {}
    for r in regions:
        c = (r.get('fieldData') or {}).get('country')
        if c:
            per_country[c] = per_country.get(c, 0) + per_region.get(r['id'], 0)
    return per_region, per_country


def write(collection, items, want, switch_on=False):
    changed, publish = [], []
    for it in items:
        n = want.get(it['id'], 0)
        fd = it.get('fieldData') or {}
        upd = {}
        if fd.get('spaces') != n:
            upd['spaces'] = n
        # A country with spaces must have its Coworking Switch on, or its
        # page shows "none listed yet" under the listings (23 Nov 2026,
        # /country/scotland). Only ever turned on here, never off.
        if switch_on and n > 0 and not fd.get('coworking-switch'):
            upd['coworking-switch'] = True
        if upd:
            changed.append({'id': it['id'], 'fieldData': upd})
            if not it.get('isDraft') and not it.get('isArchived'):
                publish.append(it['id'])
    for i in range(0, len(changed), 100):
        wf(f'/v2/collections/{collection}/items', 'PATCH', {'items': changed[i:i + 100]})
    for i in range(0, len(publish), 100):
        wf(f'/v2/collections/{collection}/items/publish', 'POST', {'itemIds': publish[i:i + 100]})
    return len(changed), len(publish)


def run(force=False):
    report = {'started': now().isoformat()}
    if not (SUPABASE_URL and SERVICE_KEY and WEBFLOW_TOKEN):
        return report
    rows = sb('sync_settings?key=eq.webflow_counts&select=value') or []
    cfg = (rows[0]['value'] if rows else None) or {}
    last = cfg.get('last_run')
    if not force and last and now() - datetime.datetime.fromisoformat(last) < EVERY:
        return report
    try:
        regions = all_items(REGIONS_ID)
        countries = all_items(COUNTRIES_ID)
        per_region, per_country = counts(live_region_ids(), regions)
        report['regions'] = write(REGIONS_ID, regions, per_region)
        report['countries'] = write(COUNTRIES_ID, countries, per_country, switch_on=True)
        report['countries_with_spaces'] = sum(1 for v in per_country.values() if v)
    except Exception as err:  # noqa: BLE001
        report['error'] = str(err)[:300]
    cfg['last_run'] = now().isoformat()
    cfg['last_report'] = report
    sb('sync_settings?on_conflict=key', 'POST',
       {'key': 'webflow_counts', 'value': cfg, 'updated_at': now().isoformat()},
       prefer='resolution=merge-duplicates,return=minimal')
    return report


if __name__ == '__main__':
    print(json.dumps(run(force='--now' in sys.argv)))
