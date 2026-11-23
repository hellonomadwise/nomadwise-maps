#!/usr/bin/env python3
"""
Area pages on nomadwise.io: "Meeting rooms in Shoreditch, London" and
"Office space in Shoreditch, London" (Jonathan, 22 Nov 2026).

One Webflow collection, "Area Pages" (URL /workspace/<slug>), one item
per area and product. Every word with a number in it comes from Nomad
Maps: the spaces in the area (venues on a live page), their live
products (venue_products) and each space's first photo. The rules that
keep these from being doorway pages are in the Nomadwise project,
growth-engine/2026-11-21-area-pages-doorway-rules.md:
  - a page only where at least 3 spaces offer the product; below 3 the
    page is taken off the site (unpublished) by this script;
  - the intro states facts of that area only;
  - one page per area and product;
  - the Request button opens the space's own request pop-up with that
    price already chosen (/coworking/<slug>?request=<price id>,
    prices.js fromLink).

Which pages exist is set in sync_settings 'area_pages':
  {"pages": [{"item": "<webflow item id>", "location": "<Locations id>",
              "product": "meeting_room" | "private_office",
              "area": "Shoreditch", "city": "London",
              "country": "England", "near": "Old Street, ...",
              "links": {...}}], "last_run": "..."}
Runs inside the website push (called from webflow_products.py), at
most once an hour; writes and publishes an item only when its text
changed. Needs SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
WEBFLOW_API_TOKEN.

Local preview: python3 scripts/webflow_area_pages.py --local rows.json
photos.json pages.json out.json (rows as [space, slug, cms id, price id,
name, category, amount, label, details]).
"""
import datetime
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
WEBFLOW_TOKEN = os.environ.get('WEBFLOW_API_TOKEN', '')
WEBFLOW_API = 'https://api.webflow.com'
AREA_PAGES_ID = '6b02e00ec85f721ebc7a0090'
SPACES_ID = '65fa86d0e0379bf78d52448d'
IMAGES_ID = '65fa86d0e0379bf78d52451b'
MIN_SPACES = 3
EVERY = datetime.timedelta(minutes=60)

e = html.escape


def now():
    return datetime.datetime.now(datetime.timezone.utc)


# ------------------------------------------------------------ the words
def money(amount):
    n = float(amount)
    return '£' + (f'{n:,.0f}' if n == int(n) else f'{n:,.2f}')


def capacity(name):
    m = re.search(r'\((\d+)\s+people\)\s*$', name or '')
    return int(m.group(1)) if m else None


def room_name(name):
    return re.sub(r'\s*\(\d+\s+people\)\s*$', '', name or '').strip()


def plain_space(name):
    """'Fora - Albert House' stays as the page calls it."""
    return (name or '').strip()


def spaces_of(rows, category):
    """{slug: {...}} for the spaces in rows that sell the category."""
    out = {}
    for space, slug, cms, pid, name, cat, amount, label, details in rows:
        s = out.setdefault(slug, {'name': space, 'slug': slug, 'cms': cms,
                                  'items': [], 'other': []})
        rec = {'id': pid, 'name': name, 'cat': cat,
               'amount': None if amount is None else float(amount),
               'label': label or '', 'details': details or []}
        (s['items'] if cat == category else s['other']).append(rec)
    return {k: v for k, v in out.items() if v['items']}


def also_line(space):
    """'Also here: desks from £450 a month, meeting rooms from £42 an hour'"""
    bits = []
    desks = [o for o in space['other'] if o['cat'] == 'coworking' and o['amount'] is not None]

    def per_day(o):
        return any(d.lower().strip() in ('per day', 'a day', 'daily') for d in o['details'])

    def per_month(o):
        if per_day(o):
            return False
        return (any('month' in d.lower() for d in o['details'])
                or re.search(r'membership|desk', o['name'], re.I) is not None)
    month = [o for o in desks if per_month(o)]
    day = [o for o in desks if per_day(o)]
    if month:
        bits.append('desks from ' + money(min(o['amount'] for o in month)) + ' a month')
    if day:
        bits.append('desks by the day from ' + money(min(o['amount'] for o in day)))
    rooms = [o for o in space['other'] if o['cat'] == 'meeting_room' and o['amount'] is not None]
    if rooms:
        bits.append('meeting rooms from ' + money(min(o['amount'] for o in rooms)) + ' an hour')
    return ('Also here: ' + ', '.join(bits)) if bits else ''


DAYS = ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
DAY_NAME = {'mon': 'Mon', 'tue': 'Tue', 'wed': 'Wed', 'thu': 'Thu', 'fri': 'Fri', 'sat': 'Sat', 'sun': 'Sun'}


def clock(t):
    """'8:30 AM' -> '8:30am', '6:00 PM' -> '6pm'."""
    m = re.match(r'^\s*(\d{1,2})(?::(\d{2}))?\s*([AP])\.?M\.?\s*$', t or '', re.I)
    if not m:
        return (t or '').strip()
    h, mi, ap = int(m.group(1)), m.group(2) or '00', m.group(3).lower()
    return f'{h}{"" if mi == "00" else ":" + mi}{ap}m'


def hours_line(hours):
    """{'mon': '8:30 AM - 6:00 PM', ..., 'sat': 'Closed'} ->
    'Open Mon to Fri 8:30am to 6pm, closed at weekends'. Empty when the
    hours are missing or not in that shape."""
    if not isinstance(hours, dict) or not all(d in hours for d in DAYS):
        return ''
    def one(v):
        v = (v or '').strip()
        if re.fullmatch(r'closed', v, re.I):
            return 'closed'
        if re.search(r'24 hours', v, re.I):
            return 'open 24 hours'
        m = re.match(r'^(.+?)\s*[-\u2013]\s*(.+)$', v)
        return f'{clock(m.group(1))} to {clock(m.group(2))}' if m else ''
    vals = [one(hours[d]) for d in DAYS]
    if '' in vals:
        return ''
    if len(set(vals)) == 1:
        return 'Open 24 hours, every day' if vals[0] == 'open 24 hours' else (
            'Closed' if vals[0] == 'closed' else f'Open every day {vals[0]}')
    runs, i = [], 0
    while i < 7:
        j = i
        while j + 1 < 7 and vals[j + 1] == vals[i]:
            j += 1
        runs.append((i, j, vals[i]))
        i = j + 1
    parts = []
    for a, b, v in runs:
        days = DAY_NAME[DAYS[a]] if a == b else (
            f'{DAY_NAME[DAYS[a]]} and {DAY_NAME[DAYS[b]]}' if b == a + 1 else f'{DAY_NAME[DAYS[a]]} to {DAY_NAME[DAYS[b]]}')
        parts.append((days, v))
    if len(parts) == 2 and parts[1] == ('Sat and Sun', 'closed') and parts[0][1] != 'closed':
        return f'Open {parts[0][0]} {parts[0][1]}, closed at weekends'
    return 'Open ' + ', '.join(f'{d} {v}' for d, v in parts)


def facts_html(space, info, area):
    """Opening hours, Google rating and a Directions link for a card."""
    v = info.get(space['slug']) or {}
    bits = []
    hl = hours_line(v.get('hours'))
    if hl:
        bits.append(f'<span class="aw-hrs">{e(hl)}</span>')
    if v.get('rating') and v.get('reviews'):
        r = float(v['rating'])
        bits.append(f'<span class="aw-rate"><span aria-hidden="true">\u2605</span> {r:.1f} '
                    f'<span class="aw-rn2">({int(v["reviews"])} Google reviews)</span></span>')
    if v.get('lat') is not None and v.get('lng') is not None:
        q = urllib.parse.quote(f'{space["name"]}, {area}')
        pid = f'&query_place_id={urllib.parse.quote(v["place_id"])}' if v.get('place_id') else ''
        href = f'https://www.google.com/maps/search/?api=1&query={q}{pid}'
        bits.append(f'<a class="aw-dir" href="{e(href)}" target="_blank" rel="noopener nofollow">Directions</a>')
    return f'<div class="aw-facts">{"".join(bits)}</div>' if bits else ''


def geo_attrs(space, info, n):
    v = info.get(space['slug']) or {}
    if v.get('lat') is None or v.get('lng') is None:
        return ''
    return f' data-n="{n}" data-lat="{float(v["lat"]):.6f}" data-lng="{float(v["lng"]):.6f}" data-name="{e(plain_space(space["name"]))}"'


def num_badge(space, info, n):
    v = info.get(space['slug']) or {}
    if v.get('lat') is None or v.get('lng') is None:
        return ''
    return f'<span class="aw-num" aria-hidden="true">{n}</span>'


def photo_html(space, photos, w, h):
    url = photos.get(space['cms'])
    if not url:
        return f'<div class="aw-ph" style="width:{w}px;height:{h}px" aria-hidden="true"></div>'
    alt = plain_space(space['name'])
    alt = alt + '{suffix}'
    return (f'<img class="aw-ph" src="{e(url)}" alt="{e(alt)}" '
            f'width="{w}" height="{h}" loading="lazy">')


def embed(inner):
    # One Webflow rich-text embed block (custom code inside rich text).
    return f'<div data-rt-embed-type="true">{inner}</div>'


def request_href(space, item):
    return f'/coworking/{space["slug"]}?request={item["id"]}'


def tabs(page, current):
    L = page['links']
    out = ['<nav class="aw-tabs" aria-label="Kind of space in ' + e(page['area']) + '">']
    for key, label in (('coworking', 'Coworking and cafes'), ('private_office', 'Office space'),
                       ('meeting_room', 'Meeting rooms')):
        href = L.get(key)
        if key == current:
            out.append(f'<span class="aw-tab aw-on" aria-current="page">{label}</span>')
        elif href:
            out.append(f'<a class="aw-tab" href="{e(href)}">{label}</a>')
    out.append('</nav>')
    return ''.join(out)


def meeting_rooms(page, rows, photos, info=None):
    info = info or {}
    area, city = page['area'], page['city']
    spaces = spaces_of(rows, 'meeting_room')
    for s in spaces.values():
        s['items'] = [i for i in s['items'] if i['amount'] is not None]
        s['items'].sort(key=lambda i: (i['amount'], capacity(i['name']) or 0, i['name']))
    spaces = {k: v for k, v in spaces.items() if v['items']}
    order = sorted(spaces.values(), key=lambda s: (s['items'][0]['amount'], s['name']))
    rooms = [(s, i) for s in order for i in s['items']]
    n_rooms, n_spaces = len(rooms), len(order)

    def cheapest(min_cap):
        c = [(i['amount'], s, i) for s, i in rooms if (capacity(i['name']) or 0) >= min_cap]
        return min(c, key=lambda x: (x[0], x[2]['name'])) if c else None

    parts = []
    for size in (4, 10, 12):
        c = cheapest(size)
        if not c:
            continue
        word = 'a boardroom' if 'boardroom' in c[2]['name'].lower() else 'a room'
        parts.append((size, word, money(c[0])))
    price_sentence = ''
    if parts:
        p0 = parts[0]
        txt = f'{p0[1].capitalize()} for {p0[0]} starts at {p0[2]} an hour'
        rest = [f'{w} for {n} at {m}' for n, w, m in parts[1:]]
        if len(rest) == 1:
            txt += f' and {rest[0]}'
        elif rest:
            txt += ', ' + ', '.join(rest[:-1]) + f' and {rest[-1]}'
        price_sentence = txt + '. '
    near = f', near {page["near"]} stations' if page.get('near') else ''
    intro = (f'Compare {n_rooms} meeting rooms in {n_spaces} {area} workspaces, hired by the hour{near}. '
             f'{price_sentence}Choose your size and send a free request. The space replies to you directly.')

    head = [tabs(page, 'meeting_room'),
            '<div class="aw-filter" role="group" aria-label="How many people?">'
            '<div class="aw-flabel">How many people?</div><div class="aw-fbtns">'
            '<button type="button" class="aw-f aw-on" data-min="0" data-max="999" aria-pressed="true">Any size</button>'
            '<button type="button" class="aw-f" data-min="1" data-max="4" aria-pressed="false">Up to 4</button>'
            '<button type="button" class="aw-f" data-min="5" data-max="8" aria-pressed="false">5 to 8</button>'
            '<button type="button" class="aw-f" data-min="9" data-max="14" aria-pressed="false">9 to 14</button>'
            '<button type="button" class="aw-f" data-min="15" data-max="999" aria-pressed="false">15 or more</button>'
            '</div></div>',
            f'<div class="aw-meta"><span class="aw-count" data-unit="rooms">{n_rooms} rooms in {n_spaces} spaces, '
            'lowest price first</span><span>Hourly prices from each space\'s own website. '
            'Check VAT and any extras with the space when it replies.</span></div>']
    blocks = [embed(''.join(head))]
    for n_card, s in enumerate(order, 1):
        caps = [capacity(i['name']) for i in s['items'] if capacity(i['name'])]
        span = (f', for {min(caps)} to {max(caps)} people' if caps and min(caps) != max(caps)
                else (f', for {caps[0]} people' if caps else ''))
        nm = len(s['items'])
        card = [f'<article class="aw-card" data-space="{e(s["slug"])}"{geo_attrs(s, info, n_card)}>',
                '<div class="aw-top">',
                photo_html(s, photos, 112, 80).replace('{suffix}', '' if area.lower() in s['name'].lower() else e(', ' + area)),
                '<div class="aw-tt">',
                f'<h2 class="aw-h2">{num_badge(s, info, n_card)}<a href="/coworking/{e(s["slug"])}">{e(plain_space(s["name"]))}</a></h2>',
                f'<div class="aw-sub">{nm} meeting room{"s" if nm != 1 else ""}{span}</div></div>',
                f'<div class="aw-from">From {money(s["items"][0]["amount"])} an hour</div></div>',
                facts_html(s, info, area),
                '<div class="aw-rows">']
        for k, i in enumerate(s['items']):
            cap = capacity(i['name'])
            extra = ' · two rooms joined' if any('joined' in d.lower() for d in i['details']) else ''
            card.append(
                f'<div class="aw-row{" aw-more" if k >= 3 else ""}" data-cap="{cap or 0}">'
                f'<div class="aw-rn"><div class="aw-rname">{e(room_name(i["name"]))}</div>'
                f'<div class="aw-rcap">{cap} people{extra}</div></div>' if cap else
                f'<div class="aw-row{" aw-more" if k >= 3 else ""}" data-cap="0">'
                f'<div class="aw-rn"><div class="aw-rname">{e(room_name(i["name"]))}</div></div>')
            card.append(f'<div class="aw-rp"><div class="aw-price">From {money(i["amount"])}</div>'
                        '<div class="aw-per">an hour</div></div>'
                        f'<a class="aw-req" href="{e(request_href(s, i))}" rel="nofollow" '
                        f'aria-label="Request {e(room_name(i["name"]))} at {e(plain_space(s["name"]))}">Request</a></div>')
        card.append('</div>')
        if nm > 3:
            card.append(f'<button type="button" class="aw-all" aria-expanded="false">See all {nm} rooms</button>')
        card.append('</article>')
        blocks.append(embed(''.join(card)))

    c4 = cheapest(4)
    c10 = cheapest(10)
    desc = f'Compare {n_rooms} meeting rooms in {n_spaces} {area} workspaces, hired by the hour.'
    if c4:
        desc += f' Rooms for 4 from {money(c4[0])} an hour'
        desc += f', for 10 from {money(c10[0])}.' if c10 else '.'
    desc += ' Send a free request.'
    return {
        'name': f'Meeting rooms in {area}, {city}',
        'h1': f'Meeting rooms in {area}, {city}',
        'intro': intro,
        'body': ''.join(blocks),
        'meta-title': f'Meeting Rooms in {area}, {city}: {n_rooms} Rooms by the Hour',
        'meta-description': desc,
        '_spaces': n_spaces,
    }


def office_space(page, rows, photos, info=None):
    info = info or {}
    area, city = page['area'], page['city']
    spaces = spaces_of(rows, 'private_office')
    for s in spaces.values():
        s['items'].sort(key=lambda i: (i['amount'] is None, i['amount'] or 0))
        s['best'] = s['items'][0]
    order = sorted(spaces.values(), key=lambda s: (s['best']['amount'] is None, s['best']['amount'] or 0, s['name']))
    priced = [s for s in order if s['best']['amount'] is not None]
    n, n_priced = len(order), len(priced)

    def unit(item):
        d = ' '.join(item['details']).lower()
        per_person = 'per person' in d or 'per desk' in d
        u = 'per person a month' if per_person else 'a month'
        if 'excludes vat' in d or '+ vat' in d or 'plus vat' in d:
            u += ', VAT not included'
        return u

    low = priced[0] if priced else None
    near = f', near {page["near"]} stations' if page.get('near') else ''
    # The opening sentence is about the area and is written by hand in
    # the page's settings ("lead"). No internal counts in the intro:
    # Jonathan, 22 Nov 2026, "sounds like internal info for me".
    lead = (page.get('lead') or f'Find a private office in {area}{near}.').strip()
    if low:
        price_bit = (f'Private offices here start at {money(low["best"]["amount"])} '
                     f'{unit(low["best"])}. ')
    else:
        price_bit = ''
    intro = (f'{lead} {price_bit}Compare {n} spaces below and send a free request '
             'to any that fit. The space replies to you directly.')

    head = [tabs(page, 'private_office'),
            f'<div class="aw-meta"><span>{n} spaces, lowest price first</span>'
            '<span>Prices from each space\'s own website. A space quotes for your team size when it replies.</span></div>']
    blocks = [embed(''.join(head))]
    for n_card, s in enumerate(order, 1):
        it = s['best']
        if it['amount'] is not None:
            price = f'From {money(it["amount"])}'
            u = unit(it)
        else:
            price = 'Price on request'
            u = 'The space quotes for your team'
        also = also_line(s)
        card = [f'<article class="aw-card aw-office" data-space="{e(s["slug"])}"{geo_attrs(s, info, n_card)}>',
                photo_html(s, photos, 176, 124).replace('{suffix}', '' if area.lower() in s['name'].lower() else e(', ' + area)),
                '<div class="aw-tt">',
                f'<h2 class="aw-h2">{num_badge(s, info, n_card)}<a href="/coworking/{e(s["slug"])}">{e(plain_space(s["name"]))}</a></h2>',
                (f'<div class="aw-also">{e(also)}</div>' if also else ''),
                facts_html(s, info, area),
                '</div>',
                '<div class="aw-side"><div><div class="aw-per">Private office</div>',
                f'<div class="aw-big">{e(price)}</div><div class="aw-per">{e(u)}</div></div>',
                '<div class="aw-btns">',
                f'<a class="aw-req" href="{e(request_href(s, it))}" rel="nofollow" '
                f'aria-label="Request a private office at {e(plain_space(s["name"]))}">Request</a>',
                f'<a class="aw-view" href="/coworking/{e(s["slug"])}">View space</a>',
                '</div></div></article>']
        blocks.append(embed(''.join(card)))

    if low:
        desc = (f'Private offices in {n} {area} workspaces, from {money(low["best"]["amount"])} '
                f'{unit(low["best"])}. Prices from each space\'s own website. Send a free request.')
        title = f'Office Space in {area}, {city}: Private Offices from {money(low["best"]["amount"])}'
    else:
        desc = f'Private offices in {n} {area} workspaces. Send a free request.'
        title = f'Office Space in {area}, {city}: Private Offices'
    return {
        'name': f'Office space in {area}, {city}',
        'h1': f'Office space in {area}, {city}',
        'intro': intro,
        'body': ''.join(blocks),
        'meta-title': title,
        'meta-description': desc,
        '_spaces': n,
    }


def breadcrumb(page, label):
    L = page['links']
    crumbs = [(page['country'], L.get('country')), (page['city'], L.get('city')),
              (page['area'], L.get('coworking'))]
    out = []
    # The country's flag (sync_settings 'area_pages' pages[].flag, the
    # country item's Flag Icon) leads the trail; app/web/crumb.js redraws
    # this breadcrumb like the rest of the site's.
    flag = page.get('flag')
    for name, href in crumbs:
        if href:
            pic = (f'<img src="{e(flag)}" alt="" width="20" height="15"> '
                   if flag and not out else '')
            out.append(f'<a href="{e(href)}">{pic}{e(name)}</a>')
    out.append(e(label))
    return '<p>' + ' / '.join(out) + '</p>'


def aside(page, product):
    L = page['links']
    how = ('<li>Pick a room and tell the space the day, the time and how many people.</li>'
           if product == 'meeting_room' else
           '<li>Pick a space and tell it your team size and when you want to start.</li>')
    links = []
    if product == 'meeting_room' and L.get('private_office'):
        links.append(f'<a href="{e(L["private_office"])}">Office space in {e(page["area"])}</a>')
    if product == 'private_office' and L.get('meeting_room'):
        links.append(f'<a href="{e(L["meeting_room"])}">Meeting rooms in {e(page["area"])}</a>')
    if L.get('coworking'):
        links.append(f'<a href="{e(L["coworking"])}">Coworking and cafes in {e(page["area"])}</a>')
    if L.get('city'):
        links.append(f'<a href="{e(L["city"])}">All of {e(page["city"])}</a>')
    inner = ('<div class="aw-mapbox"><div class="aw-map" role="img" '
             f'aria-label="Map of the spaces in {e(page["area"])}"></div></div>'
             '<div class="aw-box"><h2 class="aw-bh">How a request works</h2><ol>' + how +
             '<li>We pass it on. The space replies to you directly.</li>'
             '<li>It is not a booking and it costs nothing.</li></ol></div>'
             f'<div class="aw-box"><h2 class="aw-bh">More in {e(page["area"])}</h2>' + ''.join(links) + '</div>')
    return embed(inner)


def build(page, rows, photos, info=None):
    if page['product'] == 'meeting_room':
        f = meeting_rooms(page, rows, photos, info)
        label = 'Meeting rooms'
    else:
        f = office_space(page, rows, photos, info)
        label = 'Office space'
    f['breadcrumb'] = breadcrumb(page, label)
    f['aside'] = aside(page, page['product'])
    f['area'] = page['location']
    f['product'] = page['product']
    return f


# --------------------------------------------------------------- http
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


def info_for(location):
    q = ('venues?select=webflow_slug,lat,lng,opening_hours,google_place_id,'
         'google_rating_snapshot,google_reviews_snapshot'
         f'&webflow_location_id=eq.{urllib.parse.quote(location)}&webflow_slug=not.is.null')
    return {v['webflow_slug']: {'lat': v.get('lat'), 'lng': v.get('lng'), 'hours': v.get('opening_hours'),
                                'place_id': v.get('google_place_id'), 'rating': v.get('google_rating_snapshot'),
                                'reviews': v.get('google_reviews_snapshot')} for v in (sb(q) or [])}


def rows_for(location):
    q = ('venues?select=name,webflow_slug,webflow_cms_id,'
         'venue_products(id,name,category,amount,price_label,details,status)'
         f'&webflow_location_id=eq.{urllib.parse.quote(location)}'
         '&website_status=eq.released&website_retired_at=is.null&webflow_slug=not.is.null')
    out = []
    for v in sb(q) or []:
        for p in v.get('venue_products') or []:
            if p.get('status') != 'live':
                continue
            out.append([v['name'], v['webflow_slug'], v['webflow_cms_id'], p['id'], p['name'],
                        p['category'], p['amount'], p.get('price_label'), p.get('details') or []])
    return out


def photos_for(cms_ids, cache):
    for cid in cms_ids:
        if not cid or cid in cache:
            continue
        try:
            item = wf(f'/v2/collections/{SPACES_ID}/items/{cid}')
            ref = (item.get('fieldData') or {}).get('image-reference')
            if ref:
                img = wf(f'/v2/collections/{IMAGES_ID}/items/{ref}')
                url = (((img or {}).get('fieldData') or {}).get('image') or {}).get('url')
                if url:
                    cache[cid] = url
        except Exception:  # noqa: BLE001
            pass
    return cache


FIELDS = ('name', 'h1', 'intro', 'breadcrumb', 'body', 'aside', 'meta-title',
          'meta-description', 'area', 'product')


def same(a, b):
    norm = lambda x: re.sub(r'\s+', ' ', html.unescape(str(x or ''))).strip()  # noqa: E731
    return norm(a) == norm(b)


def run():
    report = {'started': now().isoformat(), 'pages': [], 'errors': []}
    if not (SUPABASE_URL and SERVICE_KEY and WEBFLOW_TOKEN):
        return report
    rows = sb('sync_settings?key=eq.area_pages&select=value') or []
    cfg = (rows[0]['value'] if rows else None) or {}
    last = cfg.get('last_run')
    if last and now() - datetime.datetime.fromisoformat(last) < EVERY:
        return report
    photos = cfg.get('photos') or {}
    for page in cfg.get('pages') or []:
        r = {'item': page.get('item'), 'product': page.get('product')}
        try:
            data = rows_for(page['location'])
            photos = photos_for({x[2] for x in data if x[5] == page['product']}, photos)
            f = build(page, data, photos, info_for(page['location']))
            r['spaces'] = f['_spaces']
            cur = wf(f'/v2/collections/{AREA_PAGES_ID}/items/{page["item"]}') or {}
            fd = cur.get('fieldData') or {}
            if f['_spaces'] < MIN_SPACES:
                # Doorway rule 7: under 3 spaces the page comes down.
                if cur.get('lastPublished'):
                    wf(f'/v2/collections/{AREA_PAGES_ID}/items/live', 'DELETE',
                       {'items': [{'id': page['item']}]})
                    r['done'] = 'unpublished, under 3 spaces'
                continue
            patch = {k: f[k] for k in FIELDS if not same(fd.get(k), f[k])}
            if patch:
                wf(f'/v2/collections/{AREA_PAGES_ID}/items/{page["item"]}', 'PATCH',
                   {'fieldData': patch, 'isDraft': False})
                wf(f'/v2/collections/{AREA_PAGES_ID}/items/publish', 'POST',
                   {'itemIds': [page['item']]})
                r['done'] = 'updated: ' + ', '.join(sorted(patch))
            else:
                r['done'] = 'no change'
        except Exception as err:  # noqa: BLE001
            r['error'] = str(err)[:300]
            report['errors'].append(r['error'])
        report['pages'].append(r)
    cfg['last_run'] = now().isoformat()
    cfg['photos'] = photos
    cfg['last_report'] = report['pages']
    sb('sync_settings?on_conflict=key', 'POST',
       {'key': 'area_pages', 'value': cfg, 'updated_at': now().isoformat()},
       prefer='resolution=merge-duplicates,return=minimal')
    return report


if __name__ == '__main__':
    if len(sys.argv) >= 6 and sys.argv[1] == '--local':
        rows = json.load(open(sys.argv[2]))
        photos = json.load(open(sys.argv[3]))
        pages = json.load(open(sys.argv[4]))
        info = json.load(open(sys.argv[6])) if len(sys.argv) > 6 else {}
        out = [build(p, rows, photos, info) for p in pages]
        json.dump(out, open(sys.argv[5], 'w'), ensure_ascii=False, indent=1)
        sys.exit(0)
    print(json.dumps(run(), indent=2, default=str))
