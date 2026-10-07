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
import base64
import html
import json
import os
import re
import time
import urllib.error
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


# ---------------------------------------------------------------
# A picture looked up when the link is shown (migration 159).
#
# A place nobody has screened gets its photo only when somebody opens
# its card in the app, which can be minutes before they share it and
# long after this build. So its page does not carry a fixed picture:
# it points at the database function place_photo, which answers with
# the photo kept for the place at that moment (or the app icon).
#
# That address needs the project's public key, the one the app itself
# ships to every visitor. This step of the build is not given it, so
# it is read from the environment when present and otherwise from the
# app as it is live on the site. Before any page uses the address the
# function is tried once; if anything is off, pages fall back to the
# picture known at build time.
JWT = re.compile(r'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}')


def _is_public_key(token, base):
    """True for the project's own public ("anon") key, nothing else."""
    try:
        part = token.split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(
            part + '=' * (-len(part) % 4)).decode())
    except Exception:  # noqa: BLE001
        return False
    ref = str(claims.get('ref') or '')
    return claims.get('role') == 'anon' and bool(ref) and f'//{ref}.' in base


def public_key(base, site=SITE):
    env = (os.environ.get('SUPABASE_ANON_KEY') or '').strip()
    if env and _is_public_key(env, base):
        return env
    try:
        with urllib.request.urlopen(f'{site}/main.dart.js', timeout=40) as r:
            js = r.read().decode('utf-8', 'replace')
    except Exception:  # noqa: BLE001
        return ''
    for token in dict.fromkeys(JWT.findall(js)):
        if _is_public_key(token, base):
            return token
    return ''


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: D401
        return None


def photo_address(base, pub, place_id):
    return (f'{base}/rest/v1/rpc/place_photo'
            f'?p={urllib.parse.quote(place_id, safe="")}&apikey={pub}')


def lookup_works(base, pub, tries=6):
    """Does place_photo answer with a redirect to a picture? Tried a
    few times: the function may have been made seconds ago."""
    opener = urllib.request.build_opener(_NoRedirect)
    why = 'not tried'
    for n in range(tries):
        try:
            with opener.open(photo_address(base, pub, 'build-check'),
                             timeout=20) as r:
                why = f'answered {r.status}, no redirect'
        except urllib.error.HTTPError as e:
            where = e.headers.get('Location') or ''
            if e.code in (301, 302, 303, 307, 308) \
                    and where.startswith('https://'):
                return True, ''
            why = f'answered {e.code}'
        except Exception as e:  # noqa: BLE001
            why = str(e)[:120]
        if n < tries - 1:
            time.sleep(2)
    return False, why


def venue_image(v, page_photos=None):
    """A picture of the space: the first photo on its nomadwise.io
    page, else one chosen for the page, else the first of Google's
    with a plain link."""
    for u in (page_photos or []):
        u = str(u or '').strip()
        if u.startswith('http'):
            return _sized(u)
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


def venue_card(v, page_photos=None):
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
    return (_title(v.get('name'), city), ' '.join(parts),
            venue_image(v, page_photos))


def found_card(d, live_photo=''):
    ptype = str(d.get('primary_type') or '')
    name = _clean(d.get('name'), 80)
    if 'coworking' in ptype or 'cowork' in name.lower():
        kind = 'Coworking space'
    elif ptype in ('cafe', 'coffee_shop'):
        kind = 'Cafe'
    else:
        kind = ''
    address = _clean(d.get('address'), 90)
    if kind and address:
        first = f'{kind} at {address}.'
    elif kind or address:
        first = f'{kind or address}.'
    else:
        first = ''
    desc = ' '.join(x for x in (
        first, 'Not screened for remote work yet.', TAIL) if x)
    # The photo the app showed on the place's card, when it kept one
    # (migration 158). Only Google's own image addresses are used.
    photo = str(d.get('photo_url') or '').strip()
    if not re.match(r'^https://[a-z0-9-]+\.googleusercontent\.com/', photo):
        photo = ''
    # Better still: the address that looks the photo up when the link
    # is shown, so a photo kept after this build still appears.
    return name, desc, live_photo or (_sized(photo) if photo else '')


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


def build(supabase_url, key, out_dir=OUT_DIR, fetch=None, lookup=None):
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

        cols = ('id,name,type,city,country,google_place_id,wifi_speed_mbps,'
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
        # The photos on each space's nomadwise.io page, as the nightly
        # sync last saw them (venue_page_facts, migration 127).
        page_photos = {}
        try:
            for f in rows('venue_page_facts?select=venue_id,'
                          'photo_urls:facts->photo_urls'
                          '&order=venue_id.asc', 20000):
                if isinstance(f.get('photo_urls'), list):
                    page_photos[f.get('venue_id')] = f['photo_urls']
        except Exception as e:  # noqa: BLE001
            report['page_photos_note'] = str(e)[:200]
        for v in venues:
            if write(str(v.get('google_place_id') or ''),
                     venue_card(v, page_photos.get(v.get('id')))):
                report['venues'] += 1

        try:
            found, order = None, ('&order=user_rating_count.desc.nullslast,'
                                  'google_place_id.asc')
            # Newer columns first; a column that is not there yet (HTTP
            # 400) drops back to the ones that always were.
            for cols_ in ('google_place_id,name,primary_type,address,photo_url',
                          'google_place_id,name,primary_type,address',
                          'google_place_id,name,primary_type'):
                try:
                    found = rows(f'discovered_places?select={cols_}{order}',
                                 MAX_FOUND)
                    break
                except Exception as e:  # noqa: BLE001
                    report['found_note'] = str(e)[:200]
            if found is None:
                raise RuntimeError(report.get('found_note') or 'no rows')
            pub, live = '', False
            if fetch is None or lookup is not None:
                try:
                    pub = (lookup or {}).get('key') or public_key(base)
                    if not pub:
                        report['live_picture_note'] = 'public key not found'
                    else:
                        live, why = ((lookup or {}).get('works', None)
                                     or lookup_works)(base, pub)
                        if not live:
                            report['live_picture_note'] = why
                except Exception as e:  # noqa: BLE001
                    report['live_picture_note'] = str(e)[:160]
            report['live_picture'] = bool(live)
            for d in found:
                pid = str(d.get('google_place_id') or '')
                address = photo_address(base, pub, pid) \
                    if live and ID_OK.fullmatch(pid) else ''
                if write(pid, found_card(d, address)):
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
