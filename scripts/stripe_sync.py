#!/usr/bin/env python3
"""
Stripe -> Nomad Maps: payments become Verified plans, lapses become
free again.

Runs at the end of every website push (and hourly on its own), reads
Stripe over its API with a restricted, read-only key, and needs no
webhook endpoint, which keeps the whole thing inside the existing
GitHub Actions and Supabase set-up.

Per run:
  1. Completed Checkout Sessions since the last run (paid, subscription
     mode) that are not yet in stripe_orders are recorded. Each is
     matched to a space: by the client_reference_id the payment link
     carries (a claim's id when the owner came through the claim form
     at nomadmaps.io/?claim, or a space's id when a founder sent the
     link from the control centre), else by the owner's email, else by
     a nomadwise.io link in the custom fields. A matched order sets the
     space's plan to Verified with the dates from the subscription and
     asks the sync to update the page; a claim for a space that is not
     on the site yet creates it and drops it in the queue for same-day
     review. An unmatched one waits in the control centre for a tap.
  2. Every space with a Stripe subscription is checked: renewal date
     refreshed; a cancelled or unpaid one goes back to free.

Needs: STRIPE_API_KEY (restricted key: Checkout Sessions, Subscriptions
and Customers read), SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
"""
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

STRIPE_KEY = os.environ.get('STRIPE_API_KEY', '')
SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')

report = {'started': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'orders_new': 0, 'matched': 0, 'claims': 0, 'new_spaces': 0, 'held': 0,
          'unmatched': 0, 'lapsed': 0,
          'renewals_refreshed': 0, 'errors': [], 'warnings': []}


def finish(code=0):
    print(json.dumps(report, indent=2, default=str))
    sys.exit(code)


if not STRIPE_KEY:
    report['warnings'].append('STRIPE_API_KEY not set; nothing to do')
    finish(0)
if not (SUPABASE_URL and SERVICE_KEY):
    report['errors'].append('SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY missing')
    finish(1)


def _call(url, headers, method='GET', body=None, form=False):
    data = None
    if body is not None:
        data = (urllib.parse.urlencode(body, doseq=True) if form
                else json.dumps(body)).encode()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    url, data=data, method=method, headers=headers)) as r:
                txt = r.read().decode()
                return json.loads(txt) if txt else None
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 2:
                time.sleep(3)
                continue
            raise RuntimeError(f'{e.code} {e.read().decode()[:300]}') from None


def stripe(path, params=None):
    url = 'https://api.stripe.com/v1' + path
    if params:
        url += '?' + urllib.parse.urlencode(params, doseq=True)
    return _call(url, {'Authorization': f'Bearer {STRIPE_KEY}'})


def sb(path, method='GET', body=None, prefer=None):
    headers = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
               'Content-Type': 'application/json'}
    if prefer:
        headers['Prefer'] = prefer
    return _call(f'{SUPABASE_URL}/rest/v1/{path}', headers, method, body)


now = datetime.datetime.now(datetime.timezone.utc)
now_iso = now.isoformat()


def day(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).date().isoformat()


def period_end_of(sub):
    """Newer Stripe API versions keep the period on the subscription
    items rather than the subscription; read either."""
    if not isinstance(sub, dict):
        return None
    if sub.get('current_period_end'):
        return sub['current_period_end']
    items = ((sub.get('items') or {}).get('data') or [])
    for it in items:
        if it.get('current_period_end'):
            return it['current_period_end']
    return None


def notify(title, message):
    try:
        sb('rpc/notify_phone', method='POST',
           body={'p_title': title, 'p_message': message, 'p_tags': 'moneybag'})
    except Exception:  # noqa: BLE001
        pass


# ------------------------------------------------------------ new orders
try:
    known = {r['session_id'] for r in (sb('stripe_orders?select=session_id') or [])}
except Exception as e:  # noqa: BLE001
    report['warnings'].append(f'stripe_orders read: {e} (migration 67 not applied yet?)')
    finish(0)

since = int((now - datetime.timedelta(days=45)).timestamp())
sessions = []
params = {'limit': 100, 'status': 'complete', 'created[gte]': since,
          'expand[]': ['data.subscription']}
while True:
    try:
        page = stripe('/checkout/sessions', params)
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'stripe sessions: {e}')
        break
    sessions.extend(page.get('data') or [])
    if not page.get('has_more'):
        break
    params['starting_after'] = sessions[-1]['id']

UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.I)


def custom(session, key_hint):
    for f in session.get('custom_fields') or []:
        label = ((f.get('label') or {}).get('custom') or '').lower()
        if key_hint in label or key_hint in (f.get('key') or '').lower():
            v = f.get(f.get('type') or 'text') or {}
            return (v.get('value') or '').strip()
    return ''


def find_venue(session, email, order=None):
    """Returns (venue, how, settled). `settled` is True when the match
    already did everything — the claim path sets the plan, creates the
    space if it is new, and pings the phone inside the database — so
    the caller must not patch the venue or ping a second time."""
    ref = (session.get('client_reference_id') or '').strip()
    if ref and UUID.match(ref):
        rows = sb(f'venues?id=eq.{ref}&select=id,name,webflow_cms_id,website_status')
        if rows:
            return rows[0], 'reference', False
        # Not a space: the claim form's payment link carries a claim id.
        res = sb('rpc/claim_paid', method='POST',
                 body={'p_claim': ref, 'p_order': order or {}})
        if res and res.get('venue_id'):
            report['claims'] += 1
            if res.get('new_space'):
                report['new_spaces'] += 1
            if res.get('held'):
                # An existing page: the database holds the claim for
                # approval in the control centre and pinged the phone.
                # The venue is untouched until Approve is pressed.
                report['held'] += 1
            return ({'id': res['venue_id'], 'name': res.get('name') or 'a space'},
                    'claim, awaiting approval' if res.get('held') else 'claim',
                    True)
    if email:
        rows = sb('venues?listing_owner_email=eq.'
                  f'{urllib.parse.quote(email)}&select=id,name,webflow_cms_id,website_status&limit=1')
        if rows:
            return rows[0], 'owner email', False
    link = custom(session, 'link')
    m = re.search(r'nomadwise\.io/coworking/([a-z0-9-]+)', link or '')
    if m:
        rows = sb(f'venues?webflow_slug=eq.{m.group(1)}&select=id,name,webflow_cms_id,website_status&limit=1')
        if rows:
            return rows[0], 'page link', False
    return None, None, False


for s in sessions:
    if s['id'] in known or s.get('mode') != 'subscription' \
            or s.get('payment_status') != 'paid':
        continue
    sub = s.get('subscription') or {}
    if isinstance(sub, str):
        sub = {'id': sub}
    cd = s.get('customer_details') or {}
    email = (cd.get('email') or '').strip().lower()
    name = (cd.get('name') or '').strip()
    period_end = period_end_of(sub)
    order = {
        'session_id': s['id'],
        'customer_id': s.get('customer') if isinstance(s.get('customer'), str) else (s.get('customer') or {}).get('id'),
        'subscription_id': sub.get('id'),
        'email': email or None,
        'name': name or None,
        'space_name': custom(s, 'name') or None,
        'space_link': custom(s, 'link') or None,
        'amount': (s.get('amount_total') or 0) / 100.0,
        'currency': (s.get('currency') or '').upper() or None,
        'paid_at': day(s.get('created') or int(now.timestamp())),
        'renews_at': day(period_end) if period_end else None,
        'status': 'unmatched',
        'venue_id': None,
        'matched_by': None,
    }
    try:
        venue, how, settled = find_venue(s, email, order)
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f"match {s['id']}: {e}")
        venue, how, settled = None, None, False
    if venue:
        order.update({'status': 'matched', 'venue_id': venue['id'], 'matched_by': how})
    try:
        sb('stripe_orders', method='POST', body=order, prefer='return=minimal')
        report['orders_new'] += 1
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f"order save {s['id']}: {e}")
        continue
    if not venue:
        report['unmatched'] += 1
        notify('Verified paid, needs matching',
               f"{order['space_name'] or email or 'someone'} paid; match it in Paid listings")
        continue
    if settled:
        # claim_paid() in the database already set the plan, created the
        # space if it was new, asked for the page to be rewritten and
        # pinged the phone. Nothing left to do but count it.
        report['matched'] += 1
        continue
    patch = {
        'listing_tier': 'verified',
        'listing_owner_email': email or None,
        'listing_owner_name': name or None,
        'listing_paid_at': order['paid_at'],
        'listing_renews_at': order['renews_at'],
        'stripe_customer_id': order['customer_id'],
        'stripe_subscription_id': order['subscription_id'],
        'listing_sync_requested_at': now_iso,
        'listing_synced_at': None,
        'listing_sync_error': None,
    }
    # A space that paid but is not on the site yet enters the queue,
    # so it goes through the normal proposal and approval.
    if not venue.get('webflow_cms_id') and venue.get('website_status') == 'not_on_site':
        patch['website_status'] = 'queued'
        patch['website_dismissed_at'] = None
    try:
        sb(f"venues?id=eq.{venue['id']}", method='PATCH', body=patch,
           prefer='return=minimal')
        report['matched'] += 1
        notify('Verified listing paid',
               f"{venue['name']} is now Verified ({order['currency']} {order['amount']:.0f})")
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f"plan {venue['name']}: {e}")

# ------------------------------------------------------------ renewals
LAPSED = {'canceled', 'unpaid', 'incomplete_expired', 'paused'}
try:
    paying = sb('venues?stripe_subscription_id=not.is.null'
                '&select=id,name,listing_tier,stripe_subscription_id,listing_renews_at') or []
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'paying read: {e}')
    paying = []

# A subscription Stripe no longer has (a test-mode one left behind, a
# deleted object): the link is dropped and the listing goes back to
# free. Unless every single one is missing, which means the key is
# pointing at the wrong Stripe mode; then nothing is touched.
gone = []

for v in paying:
    try:
        sub = stripe(f"/subscriptions/{v['stripe_subscription_id']}")
    except Exception as e:  # noqa: BLE001
        if '404' in str(e):
            gone.append(v)
        else:
            report['warnings'].append(f"subscription {v['name']}: {e}")
        continue
    status = sub.get('status')
    pe = period_end_of(sub)
    renews = day(pe) if pe else None
    patch = {}
    if status in LAPSED and v.get('listing_tier') == 'verified':
        patch = {'listing_tier': 'free',
                 'listing_sync_requested_at': now_iso, 'listing_synced_at': None}
        report['lapsed'] += 1
        notify('Verified listing lapsed', f"{v['name']}: subscription {status}")
    elif renews and renews != v.get('listing_renews_at') and v.get('listing_tier') == 'verified':
        patch = {'listing_renews_at': renews}
        report['renewals_refreshed'] += 1
    if patch:
        try:
            sb(f"venues?id=eq.{v['id']}", method='PATCH', body=patch,
               prefer='return=minimal')
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f"renewal {v['name']}: {e}")
    time.sleep(0.2)

if gone and len(gone) == len(paying):
    report['warnings'].append(
        f'{len(gone)} subscriptions not found in Stripe; the key looks like '
        'the wrong mode (test against live), so nothing was changed')
else:
    for v in gone:
        patch = {'stripe_subscription_id': None, 'stripe_customer_id': None}
        if v.get('listing_tier') == 'verified':
            patch.update({'listing_tier': 'free',
                          'listing_sync_requested_at': now_iso,
                          'listing_synced_at': None})
            report['lapsed'] += 1
            notify('Verified listing lapsed',
                   f"{v['name']}: subscription no longer in Stripe")
        try:
            sb(f"venues?id=eq.{v['id']}", method='PATCH', body=patch,
               prefer='return=minimal')
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f"forget subscription {v['name']}: {e}")

finish(1 if report['errors'] else 0)
