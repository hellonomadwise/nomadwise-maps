"""Exchange rates for the team (migration 290).

Price check shows "about EUR 3.70" beside a price in another currency
(Jonathan, 9 Nov 2026), so a price in Tanzanian shillings or Thai baht
can be judged at a glance. This copies the day's rates into fx_rates:
how many of each currency make one euro.

Runs in the ten-minute workflow and exits at once when the rates are
less than 20 hours old, so it fetches about once a day. Rates from
ExchangeRate-API's free daily endpoint (no key needed).

Needs: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
"""
import datetime
import json
import os
import sys
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
SOURCE = 'https://open.er-api.com/v6/latest/EUR'


def sb(path, method='GET', body=None, prefer=None):
    headers = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
               'Content-Type': 'application/json'}
    if prefer:
        headers['Prefer'] = prefer
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f'{SUPABASE_URL}/rest/v1/{path}', data=data,
                                 headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def main():
    if not SUPABASE_URL or not SERVICE_KEY:
        print('fx_rates: no database settings, skipped')
        return
    try:
        last = sb('fx_rates?select=updated_at&order=updated_at.desc&limit=1') or []
    except Exception as e:  # noqa: BLE001
        # the table comes with migration 290; a run before it is applied
        print(f'fx_rates: table not readable yet ({e}), skipped')
        return
    if last:
        at = datetime.datetime.fromisoformat(last[0]['updated_at'].replace('Z', '+00:00'))
        if datetime.datetime.now(datetime.timezone.utc) - at < datetime.timedelta(hours=20):
            print('fx_rates: fresh, nothing to do')
            return
    req = urllib.request.Request(SOURCE, headers={'User-Agent': 'nomadmaps-fx/1.0'})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read())
    if d.get('result') != 'success' or not isinstance(d.get('rates'), dict):
        print(f"fx_rates: source said {d.get('result')!r}, kept the old rates")
        sys.exit(1)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    rows = [{'currency': c.upper(), 'per_eur': float(v), 'updated_at': now}
            for c, v in d['rates'].items()
            if isinstance(v, (int, float)) and v > 0 and len(c) == 3]
    sb('fx_rates?on_conflict=currency', method='POST', body=rows,
       prefer='resolution=merge-duplicates,return=minimal')
    print(f"fx_rates: {len(rows)} rates saved ({d.get('time_last_update_utc', '')})")


if __name__ == '__main__':
    main()
