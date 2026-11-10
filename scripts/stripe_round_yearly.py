"""Round the yearly Premium prices to whole months (one-off).

Jonathan, 10 Nov 2026: the yearly plan is shown as a monthly figure
($5.75 /month), which looked random; each yearly price becomes 12 times
a whole amount ($72 a year = $6 /month) and the pill says "Save xx%".

For each pricing group: makes a new yearly Stripe price on the same
product, with the same currencies (the new amounts below), points the
group at it (pricing_groups.stripe_price_yearly, yearly_eur and the
cached amounts), and switches the old yearly price off so nobody new is
sent to it. Nobody pays yet, so no subscription changes. A group whose
yearly price already has these amounts is left alone, so running it
twice does nothing the second time.

Run by .github/workflows/stripe_round_yearly.yml ("Run workflow").
Needs a Stripe key that can write Prices.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
STRIPE_KEY = os.environ.get('STRIPE_API_KEY', '')

# minor units (cents): 12 x a whole monthly figure
NEW_YEARLY = {
    'A': {'EUR': 14400, 'GBP': 13200, 'USD': 16800, 'AUD': 24000},
    'B': {'EUR': 9600, 'GBP': 8400, 'USD': 10800},
    'C': {'EUR': 6000, 'GBP': 4800, 'USD': 7200},
    'D': {'EUR': 3600, 'GBP': 3600, 'USD': 4200},
}

report = {'changed': [], 'skipped': [], 'errors': []}


def call(url, headers, method='GET', body=None, form=False):
    data = None
    if body is not None:
        data = (urllib.parse.urlencode(body, doseq=True) if form
                else json.dumps(body)).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(
                url, data=data, method=method, headers=headers)) as r:
            txt = r.read().decode()
            return json.loads(txt) if txt else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'{e.code} {e.read().decode()[:400]}') from None


def stripe(path, params=None, method='GET'):
    url = 'https://api.stripe.com/v1' + path
    h = {'Authorization': f'Bearer {STRIPE_KEY}'}
    if method == 'GET':
        if params:
            url += '?' + urllib.parse.urlencode(params, doseq=True)
        return call(url, h)
    h['Content-Type'] = 'application/x-www-form-urlencoded'
    return call(url, h, method, params or {}, form=True)


def sb(path, method='GET', body=None):
    h = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
         'Content-Type': 'application/json', 'Prefer': 'return=minimal'}
    return call(f'{SUPABASE_URL}/rest/v1/{path}', h, method, body)


def amounts_of(price):
    per = {}
    base = (price.get('currency') or '').upper()
    if base and price.get('unit_amount') is not None:
        per[base] = int(price['unit_amount'])
    for cur, opt in (price.get('currency_options') or {}).items():
        if isinstance(opt, dict) and opt.get('unit_amount') is not None:
            per[cur.upper()] = int(opt['unit_amount'])
    return per


def main():
    if not (SUPABASE_URL and SERVICE_KEY and STRIPE_KEY):
        print('missing SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY or STRIPE_API_KEY')
        return 1
    groups = sb('pricing_groups?select=code,stripe_price_monthly,stripe_price_yearly,amounts') or []
    for g in groups:
        code = g['code']
        want = NEW_YEARLY.get(code)
        old_id = g.get('stripe_price_yearly')
        if not want or not old_id:
            report['skipped'].append(f'{code}: no target or no yearly price')
            continue
        try:
            old = stripe(f'/prices/{old_id}', {'expand[]': 'currency_options'})
            have = amounts_of(old)
            if have == want:
                report['skipped'].append(f'{code}: already {want}')
                continue
            if set(have) != set(want):
                report['errors'].append(
                    f'{code}: Stripe has currencies {sorted(have)}, the plan has '
                    f'{sorted(want)}; left alone')
                continue
            base = (old.get('currency') or '').lower()
            params = {
                'product': old['product'] if isinstance(old['product'], str)
                else old['product']['id'],
                'currency': base,
                'unit_amount': want[base.upper()],
                'recurring[interval]': 'year',
                'nickname': f'Premium yearly, group {code} (whole months, Nov 2026)',
            }
            if old.get('tax_behavior') and old['tax_behavior'] != 'unspecified':
                params['tax_behavior'] = old['tax_behavior']
            for cur, amt in want.items():
                if cur.lower() == base:
                    continue
                params[f'currency_options[{cur.lower()}][unit_amount]'] = amt
                if params.get('tax_behavior'):
                    params[f'currency_options[{cur.lower()}][tax_behavior]'] = params['tax_behavior']
            if old.get('lookup_key'):
                params['lookup_key'] = old['lookup_key']
                params['transfer_lookup_key'] = 'true'
            new = stripe('/prices', params, method='POST')
            time.sleep(0.3)
            amounts = dict(g.get('amounts') or {})
            amounts['yearly'] = want
            sb(f'pricing_groups?code=eq.{code}', 'PATCH', {
                'stripe_price_yearly': new['id'],
                'yearly_eur': want.get('EUR', 0) / 100,
                'amounts': amounts,
            })
            # the old yearly price takes no new subscriptions
            try:
                stripe(f'/prices/{old_id}', {'active': 'false'}, method='POST')
            except Exception as e:  # noqa: BLE001
                report['errors'].append(f'{code}: new price in use, old one not switched off: {e}')
            report['changed'].append({'group': code, 'old': old_id, 'new': new['id'],
                                      'from': have, 'to': want})
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f'{code}: {e}')
        time.sleep(0.3)
    print(json.dumps(report, indent=2))
    return 1 if report['errors'] else 0


if __name__ == '__main__':
    sys.exit(main())
