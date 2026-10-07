#!/usr/bin/env python3
"""Small pages that give a shared space its own link preview.

A link to the app itself (nomadmaps.io/?p=...) always previews as
"Nomadwise Maps" with the app icon, because WhatsApp and friends read
the page's tags without running the app. So each space gets a tiny
page of its own at nomadmaps.io/s/<Google place id> that carries the
space's name, where it is and a picture, and sends a person straight
on to the map at that place.

Written into app/web/s by the build (called from apply_migrations.py,
which runs before the web build copies app/web). Screened spaces all
get one; places nobody has screened yet get one for the most reviewed
MAX_FOUND. A place without a page still opens: app/web/404.html sends
/s/<id> on to the map, only without the rich preview.

Never allowed to stop the build: build() returns a small report and
swallows its own errors.
"""
import html
import json
import os
import re
import time
import urllib.parse
import urllib.request

SITE = 'https://nomadmaps.io'
DEFAULT_IMAGE = SITE + '/icons/og_square.png'
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       '..', 'app', 'web', 's')
# Google place ids: letters, digits, dash and underscore. Anything
# else is not used as a file name.
ID_OK = re.compile(r'^[A-Za-z0-9_-]{10,200}$')
MAX_FOUND = 25000        # pages for places nobody has screened yet
TIME_BUDGET = 150        # seconds for all the reading, then stop
TAIL = ('See it on Nomad Maps, the map of cafes and coworking spaces '
        'you can work from.')


def _get(url, key):
    req = urllib.request.Request(url, headers={
        'apikey': key, 'Authorization': f'Bearer {key}'})
    with urllib.request.urlopen(req, timeout=40) as resp:
        return json.loads(resp.read().decode() or '[]')


def _rows(base, key, path, cap, deadline):
    """Every row of a REST query, a thousand at a time, up to cap."""
    out, offset = [], 0
    while len(out) < cap and time.time() < deadline:
        sep = '&' if '?' in path else '?'
        page = _get(f'{base}/rest/v1/{path}{sep}limit=1000&offset={offset}',
                    key) or []
        out.extend(page)
        if len(page) < 1000:
            break
        offset += 1000
    return out[:cap]


def _sized(url, px=1200):
    """Google's own image links take a size in their =s... ending."""
    url = str(url or '').strip()
    if 'googleusercontent.com' in url:
        slash, eq = url.rfind('/'), url.rfind('=')
        if eq > slash:
            return f'{url[:eq]}=s{px}'
    return url


def _clean(text, limit):
    t = re.sub(r'\s+', ' ', str(text or '')).strip()
    return t if len(t) <= limit else t[:limit - 1].rstrip() + '…'


def venue_image(v):
    """The picture the app shows first: the page's chosen photo when
    there is one, else the first of Google's with a plain link."""
    photos = [str(u).strip() for u in (v.get('website_photos') or [])
              if str(u).strip().startswith('http')]
    on_site = v.get('website_status') in ('released', 'published_hidden')
    if photos and not (v.get('website_photos_auto') is True and not on_site):
        return _sized(photos[0])
    urls = v.get('google_photo_urls')
    if isinstance(urls, dict):
        for u in urls.values():
            if isinstance(u, str) and u.startswith('http'):
                return _sized(u)
    return ''


def _title(name, place):
    name = _clean(name, 80)
    place = _clean(place, 40)
    if not name:
        return ''
    if place and place.lower() not in name.lower():
        return f'{name}, {place}'
    return name


def venue_card(v):
    kind = 'Coworking space' if v.get('type') == 'coworking' else 'Cafe'
    city = _clean(v.get('city'), 40)
    country = _clean(v.get('country'), 40)
    where = ', '.join(x for x in (city, country) if x)
    parts = [f'{kind} in {where}.' if where else f'{kind}.']
    try:
        wifi = float(v.get('wifi_speed_mbps') or 0)
    except (TypeError, ValueError):
        wifi = 0
    if wifi > 0:
        parts.append(f'WiFi tested at {wifi:.1f} Mbps.')
    parts.append(TAIL)
    return _title(v.get('name'), city), ' '.join(parts), venue_image(v)


def found_card(d):
    ptype = str(d.get('primary_type') or '')
    if 'coworking' in ptype:
        kind = 'Coworking space'
    elif ptype in ('cafe', 'coffee_shop'):
        kind = 'Cafe'
    else:
        kind = 'Place'
    address = _clean(d.get('address'), 90)
    first = f'{kind} at {address}.' if address else f'{kind}.'
    desc = f'{first} Not screened for remote work yet. {TAIL}'
    return _clean(d.get('name'), 80), desc, ''


def page(place_id, title, desc, image):
    t = html.escape(title or 'A space', quote=True)
    d = html.escape(desc, quote=True)
    img = html.escape(image or DEFAULT_IMAGE, quote=True)
    card = 'summary_large_image' if image else 'summary'
    pid_js = json.dumps(place_id)
    pid_q = urllib.parse.quote(place_id, safe='')
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t} · Nomad Maps</title>
<meta name="robots" content="noindex">
<meta name="description" content="{d}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Nomad Maps">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:url" content="{SITE}/s/{pid_q}">
<meta property="og:image" content="{img}">
<meta name="twitter:card" content="{card}">
<meta name="twitter:title" content="{t}">
<meta name="twitter:description" content="{d}">
<meta name="twitter:image" content="{img}">
<link rel="icon" href="/favicon.png">
<script>location.replace('/?p=' + encodeURIComponent({pid_js}));</script>
</head>
<body style="font-family:system-ui,sans-serif;padding:24px;color:#142032">
<p>Opening {t} on Nomad Maps…</p>
<p><a href="/?p={pid_q}">Open the map</a></p>
</body>
</html>
"""


def build(supabase_url, key, out_dir=OUT_DIR, fetch=None):
    """Write the pages; return {'venues': n, 'found': n, ...}."""
    report = {'venues': 0, 'found': 0, 'with_picture': 0, 'skipped': 0}
    started = time.time()
    deadline = started + TIME_BUDGET
    base = supabase_url.rstrip('/')
    rows = fetch or (lambda path, cap: _rows(base, key, path, cap, deadline))
    try:
        os.makedirs(out_dir, exist_ok=True)
        written = set()

        def write(place_id, card):
            if not place_id or not ID_OK.fullmatch(place_id) \
                    or place_id in written:
                report['skipped'] += 1
                return False
            title, desc, image = card
            if not title:
                report['skipped'] += 1
                return False
            with open(os.path.join(out_dir, place_id + '.html'), 'w',
                      encoding='utf-8') as fh:
                fh.write(page(place_id, title, desc, image))
            written.add(place_id)
            if image:
                report['with_picture'] += 1
            return True

        cols = ('name,type,city,country,google_place_id,wifi_speed_mbps,'
                'website_photos,website_photos_auto,website_status,'
                'google_photo_urls')
        try:
            try:
                venues = rows('venues?google_place_id=not.is.null'
                              f'&select={cols}&order=google_place_id.asc',
                              20000)
            except Exception as e:  # noqa: BLE001
                # A column this script names may not exist yet: the
                # plain facts are enough for a title and a line.
                report['venues_note'] = str(e)[:200]
                venues = rows('venues?google_place_id=not.is.null'
                              '&select=name,type,city,google_place_id,'
                              'wifi_speed_mbps&order=google_place_id.asc',
                              20000)
        except Exception as e:  # noqa: BLE001
            # Still make the pages for the places nobody has screened.
            report['venues_error'] = str(e)[:200]
            venues = []
        for v in venues:
            if write(str(v.get('google_place_id') or ''), venue_card(v)):
                report['venues'] += 1

        try:
            try:
                found = rows('discovered_places?select=google_place_id,name,'
                             'primary_type,address'
                             '&order=user_rating_count.desc.nullslast,'
                             'google_place_id.asc', MAX_FOUND)
            except Exception as e:  # noqa: BLE001
                report['found_note'] = str(e)[:200]
                found = rows('discovered_places?select=google_place_id,name,'
                             'primary_type'
                             '&order=user_rating_count.desc.nullslast,'
                             'google_place_id.asc', MAX_FOUND)
            for d in found:
                if write(str(d.get('google_place_id') or ''), found_card(d)):
                    report['found'] += 1
        except Exception as e:  # noqa: BLE001
            report['found_error'] = str(e)[:200]
    except Exception as e:  # noqa: BLE001
        report['error'] = str(e)[:300]
    if time.time() >= deadline:
        report['out_of_time'] = True
    report['seconds'] = round(time.time() - started, 1)
    return report


if __name__ == '__main__':
    print(json.dumps(build(os.environ['SUPABASE_URL'],
                           os.environ['SUPABASE_SERVICE_ROLE_KEY']),
                     indent=2))
