"""
What each Stripe subscription charges and has brought in, for the
Money line of the control centre's Owners tab (migration 138).

Called at the end of scripts/stripe_sync.py with that script's own
`stripe` and `sb` helpers. It only reads Stripe and writes one table
(stripe_subscriptions); it never touches a listing or a plan, and
whatever goes wrong here is a warning in the report, not a failure of
the plans.

Per run (about once an hour; at once after a new payment or a plan
that ended):
  1. Ask the database which subscriptions to look at.
  2. For each: its status, its plan's price and period, and when the
     current period ends (one call).
  3. For each customer with a single subscription: every payment and
     what was refunded of it (one call, more for a long history), so
     the total collected is what was kept. This needs "Charges and
     Refunds: Read" on the restricted key. Without it the subscriptions are still
     recorded, and the card falls back on the first payment made at
     the checkout.

Money is stored in the currency's own units (12.50, not 1250).
"""
import datetime
import time


def _day(ts):
    return datetime.datetime.fromtimestamp(
        int(ts), datetime.timezone.utc).date().isoformat()


def _period_end(sub):
    """Newer Stripe API versions keep the period on the subscription
    items rather than on the subscription; read either."""
    if sub.get('current_period_end'):
        return sub['current_period_end']
    for it in ((sub.get('items') or {}).get('data') or []):
        if it.get('current_period_end'):
            return it['current_period_end']
    return None


def subscription_row(sub_id, sub):
    """The part of a subscription the card needs."""
    items = ((sub.get('items') or {}).get('data') or [])
    item = items[0] if items else {}
    price = item.get('price') or item.get('plan') or {}
    recurring = price.get('recurring') or {}
    interval = recurring.get('interval') or price.get('interval')
    count = recurring.get('interval_count') or price.get('interval_count') or 1
    unit = price.get('unit_amount')
    if unit is None:
        unit = price.get('amount')
    quantity = item.get('quantity') or 1
    customer = sub.get('customer')
    if isinstance(customer, dict):
        customer = customer.get('id')
    end = _period_end(sub)
    currency = (sub.get('currency') or price.get('currency') or '').upper() or None
    # A price with several currencies carries its main currency's
    # amount: only kept when that is the subscription's own currency.
    same_currency = (price.get('currency') or '').upper() == (currency or '')
    return {
        'subscription_id': sub_id,
        'customer_id': customer or None,
        'status': sub.get('status'),
        'currency': currency,
        'list_amount': (round(unit * quantity / 100.0, 2)
                        if isinstance(unit, (int, float)) and same_currency
                        else None),
        'period': interval if interval in ('month', 'year') else None,
        'period_count': count if isinstance(count, int) and count >= 1 else 1,
        # set to end: at the end of the period, or on a set day
        'ends_at_period_end': bool(sub.get('cancel_at_period_end')
                                   or sub.get('cancel_at')),
        'period_end': _day(end) if end else None,
    }


def payments_of(charges):
    """What was kept of a customer's payments: paid, refunds taken off.
    Returns the keys the database stores, or None when the charges are
    in more than one currency (too odd to add up)."""
    kept = []
    currencies = set()
    for c in charges:
        if not c.get('paid') or c.get('status') != 'succeeded':
            continue
        net = (c.get('amount') or 0) - (c.get('amount_refunded') or 0)
        currencies.add((c.get('currency') or '').upper())
        if net > 0:
            kept.append((int(c.get('created') or 0), net))
    if len(currencies) > 1:
        return None
    kept.sort()
    return {
        'collected': round(sum(n for _, n in kept) / 100.0, 2),
        'charges_paid': len(kept),
        'last_amount': round(kept[-1][1] / 100.0, 2) if kept else 0,
        'first_paid': _day(kept[0][0]) if kept else None,
        'last_paid': _day(kept[-1][0]) if kept else None,
    }


def charges_of(stripe, customer_id, pages=10):
    """Every charge of a customer, newest first (up to 1,000)."""
    out = []
    params = {'customer': customer_id, 'limit': 100}
    for _ in range(pages):
        page = stripe('/charges', params) or {}
        data = page.get('data') or []
        out.extend(data)
        if not page.get('has_more') or not data:
            break
        params['starting_after'] = data[-1]['id']
    return out


def run(stripe, sb, report, force=False, pause=0.2):
    report.setdefault('money_checked', 0)
    try:
        due = sb('rpc/stripe_subscriptions_due', method='POST',
                 body={'p_force': bool(force)}) or []
    except Exception as e:  # noqa: BLE001
        report['warnings'].append(
            f'money: {e} (migration 138 not applied yet?)')
        return
    if not due:
        return

    rows = []
    for d in due:
        sub_id = (d or {}).get('subscription_id')
        if not sub_id:
            continue
        try:
            sub = stripe(f'/subscriptions/{sub_id}') or {}
        except Exception as e:  # noqa: BLE001
            if str(e).startswith('404'):
                # Stripe no longer has it (a test one left behind):
                # recorded as gone, so it counts as not running.
                rows.append({'subscription_id': sub_id,
                             'customer_id': (d or {}).get('customer_id'),
                             'status': 'gone'})
            else:
                report['warnings'].append(f'money, subscription {sub_id}: {e}')
            continue
        try:
            row = subscription_row(sub_id, sub)
        except Exception as e:  # noqa: BLE001
            report['warnings'].append(f'money, subscription {sub_id}: {e}')
            continue
        if not row.get('customer_id'):
            row['customer_id'] = (d or {}).get('customer_id')
        rows.append(row)
        time.sleep(pause)

    # Every single one missing means the key points at the wrong
    # Stripe mode (test against live), as in stripe_sync.py: nothing
    # is recorded, so the card keeps what it had.
    if rows and all(r.get('status') == 'gone' for r in rows):
        report['warnings'].append(
            f'money: none of the {len(rows)} subscriptions was found in '
            'Stripe; the key looks like the wrong mode, so nothing was '
            'recorded')
        rows = []

    # A customer's payments belong to one subscription only when the
    # customer has one; with two, the first payment at the checkout
    # stands in for each (nothing is counted twice).
    per_customer = {}
    for row in rows:
        # a subscription Stripe no longer has: no payments to read
        if row.get('customer_id') and row.get('status') != 'gone':
            per_customer.setdefault(row['customer_id'], []).append(row)
    can_read = True
    shared = 0
    for customer_id, theirs in per_customer.items():
        if len(theirs) != 1:
            shared += len(theirs)
            continue
        if not can_read:
            break
        try:
            charges = charges_of(stripe, customer_id)
        except Exception as e:  # noqa: BLE001
            text = str(e)
            if text.startswith('403') or text.startswith('401') \
                    or 'permission' in text.lower():
                can_read = False
                report['warnings'].append(
                    'money: the Stripe key may not read charges, so the '
                    'total collected counts first payments only. Set '
                    '"Charges and Refunds: Read" on the restricted key to '
                    'count renewals and refunds.')
            else:
                report['warnings'].append(f'money, charges {customer_id}: {e}')
            continue
        try:
            paid = payments_of(charges)
        except Exception as e:  # noqa: BLE001
            report['warnings'].append(f'money, charges {customer_id}: {e}')
            continue
        if paid is None:
            report['warnings'].append(
                f'money, charges {customer_id}: more than one currency, left out')
        else:
            theirs[0].update(paid)
        time.sleep(pause)
    if shared:
        report['warnings'].append(
            f'money: {shared} subscriptions share a customer; their first '
            'payments stand in for their totals')

    try:
        saved = sb('rpc/set_stripe_subscriptions', method='POST',
                   body={'p': rows})
        report['money_checked'] = saved if isinstance(saved, int) else len(rows)
    except Exception as e:  # noqa: BLE001
        report['warnings'].append(f'money save: {e}')
