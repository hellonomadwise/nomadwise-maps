"""Counts every Google Places call a job makes, by the line it appears
under on the Google bill, and saves the counts per day and per job
(public.api_usage, migration 89). The control centre's "Google calls"
screen reads them, so a bill can be matched line by line: which job,
which kind of call, how many.

One line in a script turns it on:

    import google_meter; google_meter.install('enrich')

It wraps urllib's urlopen, so every Google call the script makes is
seen without touching the calls themselves. Best-effort: if anything
here fails, the job carries on exactly as before.

It also keeps the daily spending limit (migration 90): at the start
it asks the database what today's Google lookups have cost so far
(list prices), adds what this run spends, and once the day's limit is
reached it refuses further Google lookups with an error, as if Google
had refused them, until midnight UTC. Counts are saved every 200
calls as well as at the end, so the phone ping and the other jobs see
a big run while it is still going.
"""
import atexit
import datetime
import json
import os
import urllib.request

# Which Google bill line a field lands on (Places API (New), 2026).
# A call is billed at the most expensive field it asks for.
_TIER = {}
for _f in ('id', 'name', 'photos', 'attributions', 'movedPlace',
           'movedPlaceId', 'consumerAlert'):
    _TIER[_f] = 0
for _f in ('location', 'addressComponents', 'formattedAddress',
           'shortFormattedAddress', 'adrFormatAddress', 'addressDescriptor',
           'postalAddress', 'plusCode', 'types', 'viewport'):
    _TIER[_f] = 1
for _f in ('displayName', 'businessStatus', 'primaryType',
           'primaryTypeDisplayName', 'pureServiceAreaBusiness', 'openingDate',
           'entrances', 'navigationPoints', 'subDestinations', 'timeZone',
           'utcOffsetMinutes', 'googleMapsUri', 'googleMapsLinks',
           'googleMapsTypeLabel', 'iconBackgroundColor', 'iconMaskBaseUri',
           'containingPlaces'):
    _TIER[_f] = 2
for _f in ('rating', 'userRatingCount', 'priceLevel', 'priceRange',
           'internationalPhoneNumber', 'nationalPhoneNumber', 'websiteUri',
           'regularOpeningHours', 'currentOpeningHours',
           'regularSecondaryOpeningHours', 'currentSecondaryOpeningHours',
           'transitStation'):
    _TIER[_f] = 3
_NAMES = ['Essentials (IDs Only)', 'Essentials', 'Pro', 'Enterprise',
          'Enterprise + Atmosphere']

_counts = {}
_source = 'unknown'
_real_urlopen = urllib.request.urlopen

# Google's list price per 1,000 calls in US dollars (kept in step
# with public.api_list_price_usd in migration 90).
PRICE_USD = {
    'Place Details Essentials': 5, 'Place Details Pro': 17,
    'Place Details Enterprise': 20, 'Place Details Enterprise + Atmosphere': 25,
    'Place Details Photos': 7, 'Text Search Pro': 32,
    'Text Search Enterprise': 35, 'Text Search Enterprise + Atmosphere': 40,
    'Nearby Search Pro': 32, 'Nearby Search Enterprise': 35,
    'Nearby Search Enterprise + Atmosphere': 40,
    'Autocomplete Requests': 2.83,
}
_budget = {'spent': 0.0, 'limit': None, 'fx': 0.75, 'paused': []}
_run_gbp = 0.0
_unsaved = 0
_blocked = 0


class DailyLimitReached(Exception):
    """Raised instead of calling Google once today's limit is spent."""


def _tier(mask):
    top = 0
    for f in (mask or '').split(','):
        f = f.strip()
        if f.startswith('places.'):
            f = f[len('places.'):]
        f = f.split('.')[0]
        if not f:
            continue
        # Anything not listed above (reviews, summaries, amenities...)
        # is the Atmosphere line, the dearest; '*' is everything.
        top = max(top, _TIER.get(f, 4))
    return top


def bill_line(url, mask):
    """The Google bill's name for this call, or None if not Places."""
    if 'places.googleapis.com' not in url:
        return None
    path = url.split('places.googleapis.com/v1/', 1)[-1].split('?', 1)[0]
    if path.endswith('/media'):
        return 'Place Details Photos'
    if path.startswith('places:autocomplete'):
        return 'Autocomplete Requests'
    t = _tier(mask)
    if path.startswith('places:searchText'):
        return 'Text Search ' + ('Essentials (IDs Only)' if t == 0
                                 else _NAMES[max(t, 2)])
    if path.startswith('places:searchNearby'):
        return 'Nearby Search ' + _NAMES[max(t, 2)]
    return 'Place Details ' + _NAMES[t]


def _mask_of(req):
    if isinstance(req, urllib.request.Request):
        for k, v in req.header_items():
            if k.lower() == 'x-goog-fieldmask':
                return v
    return ''


def _metered(req, *a, **kw):
    url = req.full_url if isinstance(req, urllib.request.Request) else str(req)
    line = None
    try:
        line = bill_line(url, _mask_of(req))
    except Exception:  # noqa: BLE001
        pass
    if line is None:
        return _real_urlopen(req, *a, **kw)
    global _run_gbp, _unsaved, _blocked
    price = PRICE_USD.get(line, 0) / 1000.0 * _budget['fx']
    lim = _budget['limit']
    if price > 0 and lim is not None and _budget['spent'] + _run_gbp >= lim:
        _blocked += 1
        raise DailyLimitReached(
            f'daily Google limit of £{lim} reached; not calling Google')
    # A founder can pause one job from the Google calls page (migration
    # 111): it then asks Google nothing, the other jobs carry on.
    if _source in (_budget.get('paused') or []):
        _blocked += 1
        raise DailyLimitReached(
            f'"{_source}" is paused in the app (Google calls); not calling Google')
    row = _counts.setdefault(line, [0, 0])
    try:
        resp = _real_urlopen(req, *a, **kw)
    except Exception:
        row[1] += 1        # refused calls are not billed; counted apart
        raise
    row[0] += 1
    _run_gbp += price
    _unsaved += 1
    if _unsaved >= 200:
        _save()
    return resp


_saved = {}


def _save():
    """Adds the calls not yet saved to today's counts, then refreshes
    today's spend from the database (other jobs and visitors too)."""
    global _unsaved, _run_gbp
    _unsaved = 0
    delta = {}
    for k, v in _counts.items():
        s = _saved.get(k, [0, 0])
        if v[0] - s[0] or v[1] - s[1]:
            delta[k] = {'calls': v[0] - s[0], 'errors': v[1] - s[1]}
    url = os.environ.get('SUPABASE_URL', '').rstrip('/')
    key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
    if not (url and key):
        return
    if delta and _post('record_api_usage', {
            'p_day': datetime.datetime.now(
                datetime.timezone.utc).date().isoformat(),
            'p_source': _source, 'p_counts': delta}) is not False:
        for k, v in _counts.items():
            _saved[k] = list(v)
        _run_gbp = 0.0      # now inside the database's figure
    _refresh_budget()


def _post(fn, payload):
    url = os.environ.get('SUPABASE_URL', '').rstrip('/')
    key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
    try:
        with _real_urlopen(urllib.request.Request(
                f'{url}/rest/v1/rpc/{fn}', data=json.dumps(payload).encode(),
                method='POST',
                headers={'apikey': key, 'Authorization': f'Bearer {key}',
                         'Content-Type': 'application/json'}),
                timeout=20) as r:
            txt = r.read().decode()
            return json.loads(txt) if txt else None
    except Exception as e:  # noqa: BLE001
        print(f'google_meter: {fn} failed ({e})')
        return False


def _refresh_budget():
    b = _post('google_budget', {})
    if isinstance(b, dict) and b.get('limit_gbp') is not None:
        _budget['spent'] = float(b.get('spent_gbp') or 0)
        _budget['limit'] = float(b['limit_gbp'])
        _budget['fx'] = float(b.get('fx') or 0.75)
        _budget['paused'] = [str(x) for x in (b.get('paused') or [])]


def _flush():
    summary = {k: {'calls': v[0], 'errors': v[1]} for k, v in _counts.items()}
    if summary:
        print('Google calls this run (' + _source + '):',
              json.dumps(summary, indent=2))
    if _blocked:
        print(f'Daily Google limit reached or job paused: {_blocked} calls '
              'not made.')
    _save()


def install(source):
    global _source
    _source = source
    if urllib.request.urlopen is not _metered:
        urllib.request.urlopen = _metered
        atexit.register(_flush)
        if os.environ.get('SUPABASE_URL') and os.environ.get(
                'SUPABASE_SERVICE_ROLE_KEY'):
            _refresh_budget()
