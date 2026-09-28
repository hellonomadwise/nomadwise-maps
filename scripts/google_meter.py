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
    row = _counts.setdefault(line, [0, 0])
    try:
        resp = _real_urlopen(req, *a, **kw)
    except Exception:
        row[1] += 1        # refused calls are not billed; counted apart
        raise
    row[0] += 1
    return resp


def _flush():
    if not _counts:
        return
    url = os.environ.get('SUPABASE_URL', '').rstrip('/')
    key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
    summary = {k: {'calls': v[0], 'errors': v[1]} for k, v in _counts.items()}
    print('Google calls this run (' + _source + '):',
          json.dumps(summary, indent=2))
    if not (url and key):
        return
    body = json.dumps({
        'p_day': datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
        'p_source': _source,
        'p_counts': summary,
    }).encode()
    try:
        _real_urlopen(urllib.request.Request(
            f'{url}/rest/v1/rpc/record_api_usage', data=body, method='POST',
            headers={'apikey': key, 'Authorization': f'Bearer {key}',
                     'Content-Type': 'application/json'}), timeout=20).read()
    except Exception as e:  # noqa: BLE001
        print(f'Google call counts not saved (migration 89 not run yet?): {e}')


def install(source):
    global _source
    _source = source
    if urllib.request.urlopen is not _metered:
        urllib.request.urlopen = _metered
        atexit.register(_flush)
