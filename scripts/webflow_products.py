#!/usr/bin/env python3
"""
Products on nomadwise.io <-> Nomad Maps (migration 131).

A coworking page on nomadwise.io lists what the space sells (day pass,
month pass, meeting room, ...). Each is an item in the Webflow
"Products" collection. Nomad Maps keeps a copy (venue_products), a
founder decides every change in the control centre (Price check), and
this script is the only thing that writes them to Webflow.

Two jobs, both inside the ten-minute website push:

1. Write what a founder approved. For each change with Go pressed:
     update  the product's name, price, details or category
     remove  take the product off the live page and archive it
     add     make a new product, copied from a sibling for the page's
             settings (currency, country, photo, commission)
   and for each Undo, the reverse. A live product is republished so the
   change shows. The result is reported back with product_change_done().

2. About once a day, copy the whole Products collection into
   venue_products (set_venue_products), so a product edited by hand in
   Webflow is seen in Nomad Maps too.

Nothing here runs unless a founder pressed Go on that very change (the
daily copy only reads Webflow). The price on the page is what the
page's own request form quotes back to a visitor, so it must be the
price on the space's own website; that is what the check is for.

Exits in about a second when there is nothing to write and the copy is
not due. Needs SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and
WEBFLOW_API_TOKEN (CMS read and write).

Output: printed, and ci-debug/webflow_products_report.json
"""
import datetime
import html
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
WEBFLOW_TOKEN = os.environ.get('WEBFLOW_API_TOKEN', '')

WEBFLOW_API = 'https://api.webflow.com'
PRODUCTS_ID = '67c95ef09fb5dd1f966918df'
CATEGORIES_ID = '6823b9053b6034fd12de5158'
CURRENCIES_ID = '67c95f1d6ed71330510b57a1'
PAGE = 100
PAUSE = 1.1   # between Webflow calls: 60 a minute is the ceiling

# Our four categories and the slugs of the Webflow Categories items.
CATEGORY_SLUG = {'coworking': 'coworking', 'meeting_room': 'meeting-room',
                 'private_office': 'private-office', 'other': 'other-options'}
CATEGORY_OF = {v: k for k, v in CATEGORY_SLUG.items()}


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


report = {'started': now_iso(), 'to_write': 0, 'written': 0, 'undone': 0,
          'failed': 0, 'skipped': 0, 'copied': None, 'errors': [], 'warnings': []}


def finish(code=0):
    report['finished'] = now_iso()
    try:
        os.makedirs('ci-debug', exist_ok=True)
        with open('ci-debug/webflow_products_report.json', 'w') as fh:
            json.dump(report, fh, indent=2, default=str)
    except Exception:  # noqa: BLE001
        pass
    print(json.dumps(report, indent=2, default=str))
    sys.exit(code)


# ---------------------------------------------------------------- http
def _call(url, headers, method='GET', body=None, retries=3):
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    url, data=data, method=method, headers=headers),
                    timeout=40) as r:
                txt = r.read().decode()
                return json.loads(txt) if txt else None
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries - 1:
                time.sleep(int(e.headers.get('Retry-After', '15')) + 1)
                continue
            try:
                detail = e.read().decode()[:300]
            except Exception:  # noqa: BLE001
                detail = ''
            err = RuntimeError(f'{e.code} {detail}'.strip())
            err.code = e.code
            raise err from None


def wf(path, params=None):
    url = WEBFLOW_API + path
    if params:
        url += '?' + urllib.parse.urlencode(params)
    return _call(url, {'Authorization': f'Bearer {WEBFLOW_TOKEN}',
                       'accept': 'application/json'})


def wf_all(path):
    """Every item of a collection. A read that comes back short (an
    empty page before the total is reached) is an error, not a shorter
    list: the daily copy would take the missing items for removed."""
    out, offset, total = [], 0, None
    while True:
        page = wf(path, {'limit': PAGE, 'offset': offset}) or {}
        items = page.get('items') or []
        out.extend(items)
        total = (page.get('pagination') or {}).get('total', total)
        offset += len(items)
        if not items or (total is not None and offset >= total):
            break
        time.sleep(0.4)
    if total is not None and len(out) < total:
        raise RuntimeError(f'Webflow returned {len(out)} of {total} items')
    return out


def wf_write(path, method, body):
    return _call(WEBFLOW_API + path,
                 {'Authorization': f'Bearer {WEBFLOW_TOKEN}',
                  'accept': 'application/json',
                  'Content-Type': 'application/json'},
                 method=method, body=body)


def sb(path, method='GET', body=None, prefer=None):
    headers = {'apikey': SERVICE_KEY,
               'Authorization': f'Bearer {SERVICE_KEY}',
               'Content-Type': 'application/json'}
    if prefer:
        headers['Prefer'] = prefer
    return _call(f'{SUPABASE_URL}/rest/v1/{path}', headers, method, body)


# ------------------------------------------------- Webflow <-> product
_refs = {}


def refs():
    """The Webflow items a product points at: category and currency,
    both ways. Read once, when first needed."""
    if not _refs:
        cats = wf_all(f'/v2/collections/{CATEGORIES_ID}/items')
        curs = wf_all(f'/v2/collections/{CURRENCIES_ID}/items')
        _refs['cat_id'] = {}      # our category -> Webflow item id
        _refs['cat_of'] = {}      # Webflow item id -> our category
        for c in cats:
            ours = CATEGORY_OF.get((c.get('fieldData') or {}).get('slug'))
            if ours:
                _refs['cat_id'][ours] = c['id']
                _refs['cat_of'][c['id']] = ours
        _refs['cur_id'] = {}      # EUR -> Webflow item id
        _refs['cur_of'] = {}      # Webflow item id -> EUR
        for c in curs:
            fd = c.get('fieldData') or {}
            code = ''
            for cand in (fd.get('slug'), fd.get('name')):
                m = re.fullmatch(r'[A-Za-z]{3}', str(cand or '').strip())
                if m:
                    code = m.group(0).upper()
                    break
            if code:
                _refs['cur_id'][code] = c['id']
                _refs['cur_of'][c['id']] = code
        time.sleep(PAUSE)
    return _refs


def tidy(text):
    """One line, single spaces, plain hyphens (as product_tidy() in the
    database does, so both sides compare alike)."""
    t = str(text or '').replace('—', ' - ').replace('–', '-')
    t = t.replace('‍', '').replace('\xa0', ' ')
    return ' '.join(t.split())


def details_of(rich):
    """The bullet lines of a product's Tooltip (Rich text)."""
    out = []
    for m in re.finditer(r'<li[^>]*>(.*?)</li>', rich or '', flags=re.S):
        t = tidy(html.unescape(re.sub(r'<[^>]+>', ' ', m.group(1))))
        if t:
            out.append(t)
    if not out and str(rich or '').strip():
        t = tidy(html.unescape(re.sub(r'<[^>]+>', ' ', rich)))
        if t:
            out.append(t)
    return out


def details_html(lines):
    lines = [tidy(x) for x in (lines or []) if tidy(x)]
    if not lines:
        return None
    return '<ul>' + ''.join(f'<li>{html.escape(x, quote=False)}</li>'
                            for x in lines) + '</ul>'


def number(v):
    """An amount as JSON should carry it: 150, not 150.0."""
    if v is None or v == '':
        return None
    f = float(v)
    return int(f) if f == int(f) else round(f, 2)


def vat_of(text):
    t = str(text or '').strip().lower()
    return True if t == 'true' else False if t == 'false' else None


def label_currency(label):
    """A currency written in a price label ("100 AED"), for the few
    products with no Currency item set."""
    for code in re.findall(r'\b[A-Z]{3}\b', str(label or '')):
        if code not in ('VAT', 'BHT'):
            return code
    return None


def product_of(fd):
    """A Webflow product's fields as the database holds a product."""
    r = refs()
    return {
        'name': tidy(fd.get('product-type-name') or fd.get('name')),
        'category': r['cat_of'].get(fd.get('category-2'), 'coworking'),
        'amount': number(fd.get('amount')),
        'currency': r['cur_of'].get(fd.get('product-currency'))
                    or label_currency(fd.get('amount-label')),
        'label': tidy(fd.get('amount-label')),
        'starting_from': bool(fd.get('starting-from')),
        'vat_included': vat_of(fd.get('vat-included-2')),
        'details': details_of(fd.get('tooltip-rich-text')),
    }


def plain(p):
    """A product as two versions of it are compared: tidied text and
    plain numbers, whichever side it came from."""
    p = p or {}
    return {
        'name': tidy(p.get('name')),
        'amount': number(p.get('amount')),
        'label': tidy(p.get('label')),
        'currency': (p.get('currency') or '').upper() or None,
        'category': p.get('category') or 'coworking',
        'details': [tidy(x) for x in (p.get('details') or []) if tidy(x)],
        'vat_included': p.get('vat_included'),
        'starting_from': bool(p.get('starting_from')),
    }


def patch_for(target, fd, basis):
    """The fields to write so the Webflow item reads like `target`.
    Only what the change itself changes (where `target` differs from
    `basis`, the version it started from) is written, and only where
    the page does not say it already. So a price change touches the
    price alone, and something edited by hand in Webflow since (the
    details, say) is left as it is."""
    r = refs()
    now_ = product_of(fd)
    want, was = plain(target), plain(basis)
    out = {}

    def changes(key):
        return want[key] != was[key] and want[key] != now_[key]

    if changes('name') and want['name']:
        out['product-type-name'] = want['name']
        # The item's own name is "<Space> <Product>"; keep the space.
        old_type = str(fd.get('product-type-name') or '')
        full = str(fd.get('name') or '')
        if old_type and full.endswith(old_type):
            out['name'] = (full[:len(full) - len(old_type)] + want['name'])[:250]
    if changes('amount'):
        out['amount'] = want['amount']
    if changes('label'):
        out['amount-label'] = want['label'] or None
    if changes('currency') and want['currency']:
        if want['currency'] not in r['cur_id']:
            raise ValueError(f"The currency {want['currency']} is not set up on "
                             'the website (Webflow, Currencies); add it there first.')
        out['product-currency'] = r['cur_id'][want['currency']]
    if changes('category'):
        if want['category'] not in r['cat_id']:
            raise ValueError('This category is not set up on the website.')
        out['category-2'] = r['cat_id'][want['category']]
    if changes('details'):
        out['tooltip-rich-text'] = details_html(want['details'])
    if changes('vat_included') and want['vat_included'] is not None:
        out['vat-included-2'] = 'TRUE' if want['vat_included'] else 'FALSE'
    if changes('starting_from'):
        out['starting-from'] = want['starting_from']
    return out


def is_live(item):
    return bool(item.get('lastPublished')) and not item.get('isDraft') \
        and not item.get('isArchived')


def publish(item_id):
    res = wf_write(f'/v2/collections/{PRODUCTS_ID}/items/publish', 'POST',
                   {'itemIds': [item_id]}) or {}
    time.sleep(PAUSE)
    # Webflow answers 200 and lists what it could not publish.
    if res.get('errors') and item_id not in (res.get('publishedItemIds') or []):
        raise RuntimeError('Webflow could not publish it: '
                           f"{str(res.get('errors'))[:200]}")


def get_item(item_id):
    if not item_id:
        raise ValueError('This product is not on the website.')
    try:
        item = wf(f'/v2/collections/{PRODUCTS_ID}/items/{item_id}') or {}
    except RuntimeError as e:
        if getattr(e, 'code', None) == 404:
            raise ValueError('This product could not be found on the '
                             'website; it may have been deleted in Webflow.') from None
        raise
    time.sleep(PAUSE)
    if not item.get('id'):
        raise ValueError('This product could not be found on the website.')
    return item


def still_wanted(c):
    """Asked just before the first write. A founder may have taken the
    change back, or pressed Go on another wording, since this run read
    it; if not, this claims it, and the control centre holds off until
    product_change_done()."""
    return bool(sb('rpc/product_change_begin', method='POST',
                   body={'p_id': c['id'], 'p_status': c['status'],
                         'p_decided_at': c.get('decided_at')}))


# ------------------------------------------------------------- writing
def write_fields(c, target, basis):
    """Make the product on the website read like `target` in what the
    change changes. Returns what the page read before and reads after,
    or None when the change was taken back in the meantime."""
    item_id = (c.get('product') or {}).get('webflow_item_id')
    item = get_item(item_id)
    fd = item.get('fieldData') or {}
    before = product_of(fd)
    patch = patch_for(target, fd, basis)
    if not still_wanted(c):
        return None
    if patch:
        wf_write(f'/v2/collections/{PRODUCTS_ID}/items/{item_id}', 'PATCH',
                 {'fieldData': patch})
        time.sleep(PAUSE)
    # Republished also when nothing differed: an earlier run may have
    # stopped between the write and the publish.
    if is_live(item):
        publish(item_id)
    after = product_of(dict(fd, **patch))
    # "Before" is only what this run found when this run changed
    # something: on a repeat (the page already reads like the target)
    # the version kept with the change is the true one.
    return (before if patch else None), after


def take_down(c, item_id):
    """Off the live page, then archived (kept in Webflow, so it can be
    put back)."""
    get_item(item_id)
    if not still_wanted(c):
        return False
    try:
        wf_write(f'/v2/collections/{PRODUCTS_ID}/items/{item_id}/live',
                 'DELETE', None)
    except RuntimeError as e:
        code = getattr(e, 'code', None)
        if code not in (404, 409):
            raise
        if code == 409:
            # 409 usually means "not published"; make sure of it
            # rather than record a product as off the page while it
            # still shows.
            time.sleep(PAUSE)
            try:
                live = wf(f'/v2/collections/{PRODUCTS_ID}/items/{item_id}/live')
            except RuntimeError as e2:
                if getattr(e2, 'code', None) != 404:
                    raise
                live = None
            if live and live.get('id'):
                raise RuntimeError('Webflow would not take it off the live '
                                   'page (409).') from None
    time.sleep(PAUSE)
    wf_write(f'/v2/collections/{PRODUCTS_ID}/items/{item_id}', 'PATCH',
             {'isArchived': True, 'isDraft': True})
    time.sleep(PAUSE)
    return True


def put_back(c, item_id):
    get_item(item_id)
    if not still_wanted(c):
        return False
    wf_write(f'/v2/collections/{PRODUCTS_ID}/items/{item_id}', 'PATCH',
             {'isArchived': False, 'isDraft': False})
    time.sleep(PAUSE)
    publish(item_id)
    return True


def slugify(x):
    x = re.sub(r"['’‘`]", '', x or '')
    x = unicodedata.normalize('NFKD', x)
    x = ''.join(ch for ch in x if not unicodedata.combining(ch))
    x = re.sub(r'[^a-z0-9]+', '-', x.lower()).strip('-')
    return re.sub(r'-{2,}', '-', x)


# New products made in this run, by space (for their place in the list).
_added = {}


def type_id(name):
    """The old "Product Type ID": the name in one word (DayPass)."""
    words = re.findall(r'[A-Za-z0-9()]+', name or '')
    return ''.join(w[:1].upper() + w[1:] for w in words)[:80] or 'Product'


def make_new(c):
    """A new product for a page, with the page's settings copied from
    one of its other products. Returns (item id, slug), or None when
    the change was taken back."""
    final = c.get('final') or {}
    venue = c.get('venue') or {}
    sibling_id = c.get('sibling')
    if not sibling_id:
        raise ValueError('This page has no products on the website yet, so '
                         'there is nothing to copy its settings from. Add '
                         'the first one in Webflow.')
    sib = get_item(sibling_id)
    sfd = sib.get('fieldData') or {}
    r = refs()
    name = tidy(final.get('name'))
    base = slugify(f"{venue.get('webflow_slug') or venue.get('name') or 'space'}-{name}")[:200]
    cur = (final.get('currency') or '').upper() or None
    if cur and cur not in r['cur_id']:
        raise ValueError(f'The currency {cur} is not set up on the website '
                         '(Webflow, Currencies); add it there first.')
    # The space's name as its other products carry it.
    sib_type = str(sfd.get('product-type-name') or '')
    sib_full = str(sfd.get('name') or '')
    space = (sib_full[:len(sib_full) - len(sib_type)].strip()
             if sib_type and sib_full.endswith(sib_type) else venue.get('name') or '')
    fields = {
        'name': f'{space} {name}'.strip()[:250],
        'slug': base,
        'coworking-space': sfd.get('coworking-space') or venue.get('webflow_cms_id'),
        'product-currency': r['cur_id'].get(cur) if cur else sfd.get('product-currency'),
        'online': True,
        'commission-percentage': sfd.get('commission-percentage'),
        'product-type-name': name,
        'amount': number(final.get('amount')),
        'amount-label': tidy(final.get('label')) or None,
        'withholding-tax-covered': bool(sfd.get('withholding-tax-covered')),
        'product-id': type_id(name),
        'order': int(c.get('next_position') or 1),
        'tooltip-rich-text': details_html(final.get('details')),
        'discount-applied': False,
        'country-of-product': sfd.get('country-of-product'),
        'vat-included-2': ('TRUE' if final.get('vat_included') else 'FALSE')
                          if final.get('vat_included') is not None
                          else sfd.get('vat-included-2'),
        'images': sfd.get('images'),
        'price-text-colour': sfd.get('price-text-colour') or '#333',
        'starting-from': False,
        'category-2': r['cat_id'].get(final.get('category') or 'coworking'),
        'affiliate-model-applied': False,
    }
    fields = {k: v for k, v in fields.items() if v is not None}
    # Two products added to one page in the same run: one after the
    # other, not both in the same place.
    fields['order'] += _added.get(venue.get('id'), 0)
    if not still_wanted(c):
        return None
    # A run that stopped after making the item must not make a second
    # one: look for the address first. The address is the page's own
    # plus the product's name; when that is taken by something else,
    # a few characters of this change's id are added.
    chosen, mine = None, None
    for slug_ in (base, f"{base}-{str(c['id'])[:6]}"):
        found = (wf(f'/v2/collections/{PRODUCTS_ID}/items',
                    {'slug': slug_, 'limit': 5}) or {}).get('items') or []
        time.sleep(PAUSE)
        hit = next((i for i in found
                    if (i.get('fieldData') or {}).get('slug') == slug_), None)
        if hit is None:
            chosen = slug_
            break
        hfd = hit.get('fieldData') or {}
        same_page = hfd.get('coworking-space') == fields.get('coworking-space')
        same_product = tidy(hfd.get('product-type-name')).lower() == name.lower()
        # Ours to reuse when it is the same product (an interrupted
        # run), or one of this page's taken off earlier. A different
        # product that is live under this address is left alone.
        if same_page and (same_product or not is_live(hit)):
            chosen, mine = slug_, hit
            break
    if chosen is None:
        raise ValueError('The address for this product is already taken on '
                         'the website; give it a slightly different name.')
    fields['slug'] = chosen
    if mine:
        item_id = mine['id']
        body = {'isArchived': False, 'isDraft': False,
                'fieldData': {k: v for k, v in fields.items() if k != 'slug'}}
        wf_write(f'/v2/collections/{PRODUCTS_ID}/items/{item_id}', 'PATCH', body)
    else:
        made = wf_write(f'/v2/collections/{PRODUCTS_ID}/items', 'POST',
                        {'isArchived': False, 'isDraft': False,
                         'fieldData': fields})
        item_id = (made or {}).get('id')
        if not item_id:
            raise RuntimeError(f'Webflow gave no id for the new product: {made}')
    time.sleep(PAUSE)
    # Shown only where the page's other products are live.
    if is_live(sib):
        publish(item_id)
    _added[venue.get('id')] = _added.get(venue.get('id'), 0) + 1
    return item_id, chosen


def apply_change(c):
    """One approved change, or one undo. Returns the arguments for
    product_change_done(), or None when it was taken back."""
    action, undo = c.get('action'), c.get('status') == 'undo_requested'
    item_id = (c.get('product') or {}).get('webflow_item_id')
    if action == 'update':
        target = c.get('before') if undo else c.get('final')
        basis = c.get('final') if undo else c.get('before')
        if not target or not basis:
            raise ValueError('There is nothing to write for this change.')
        wrote = write_fields(c, target, basis)
        if wrote is None:
            return None
        return {'p_before': None if undo else wrote[0], 'p_after': wrote[1]}
    if action == 'remove':
        ok = put_back(c, item_id) if undo else take_down(c, item_id)
        return {} if ok else None
    if action == 'add':
        if undo:
            return {} if take_down(c, item_id) else None
        made = make_new(c)
        return None if made is None else {'p_item': made[0], 'p_item_slug': made[1]}
    raise ValueError('This kind of change cannot be written yet.')


def report_back(body):
    """Tell the database how a write went. Tried three times: the
    write itself has happened by now, so this must not be lost."""
    last = None
    for attempt in range(3):
        try:
            return sb('rpc/product_change_done', method='POST', body=body)
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(2 * (attempt + 1))
    raise last


def write_changes(changes):
    for c in changes:
        undo = c.get('status') == 'undo_requested'
        label = f"{(c.get('venue') or {}).get('name')}: " \
                f"{((c.get('final') or c.get('before') or {}).get('name')) or (c.get('product') or {}).get('name')}"
        # The write to Webflow. If it fails, the change is marked as
        # failed with the reason, for the founder to see.
        try:
            done = apply_change(c)
        except Exception as e:  # noqa: BLE001
            report['failed'] += 1
            why = str(e)[:300]
            report['warnings'].append(f'product {label}: {why}')
            try:
                report_back({'p_id': c['id'], 'p_ok': False, 'p_error': why})
            except Exception:  # noqa: BLE001
                pass
            continue
        if done is None:
            report['skipped'] += 1   # taken back since this run read it
            continue
        # The report back. Kept apart from the write: if this fails the
        # page HAS been changed, so it is never recorded as a failure.
        # The change stays claimed; a later run writes it again (which
        # changes nothing more) and reports then.
        body = {'p_id': c['id'], 'p_ok': True}
        body.update(done)
        try:
            res = report_back(body) or {}
        except Exception as e:  # noqa: BLE001
            report['unrecorded'] = report.get('unrecorded', 0) + 1
            report['warnings'].append(
                f'product {label}: written to the website but not recorded '
                f'({str(e)[:160]}); the next run repeats it')
            continue
        if res.get('ok'):
            report['undone' if undo else 'written'] += 1
        else:
            report['skipped'] += 1
            report['warnings'].append(
                f"product {label}: written, but the database said "
                f"\"{res.get('why')}\"")


# ------------------------------------------------------- the daily copy
def copy_from_webflow():
    items = wf_all(f'/v2/collections/{PRODUCTS_ID}/items')
    rows = []
    for i in items:
        fd = i.get('fieldData') or {}
        p = product_of(fd)
        extra = {}
        if fd.get('discount-applied'):
            extra['discount_applied'] = True
            extra['original_label'] = fd.get('original-selling-amount-label')
            extra['discount_label'] = fd.get('discount-amount-label')
        link = fd.get('affiliate-link')
        if fd.get('affiliate-model-applied') or link:
            extra['affiliate'] = True
            extra['affiliate_link'] = link.get('url') if isinstance(link, dict) else link
        if fd.get('product-id'):
            extra['type_id'] = fd.get('product-id')
        rows.append({
            'item': i.get('id'), 'slug': fd.get('slug'),
            'venue_cms': fd.get('coworking-space'),
            'name': p['name'], 'category': p['category'], 'amount': p['amount'],
            'currency': p['currency'], 'label': p['label'],
            'starting_from': p['starting_from'], 'vat_included': p['vat_included'],
            'details': p['details'],
            'position': int(fd['order']) if isinstance(fd.get('order'), (int, float)) else 0,
            'live': not i.get('isArchived') and not i.get('isDraft'),
            'site_updated_at': i.get('lastUpdated'),
            'extra': extra,
        })
    result = sb('rpc/set_venue_products', method='POST',
                body={'p': rows, 'p_full': True}) or {}
    result['read'] = len(rows)
    report['copied'] = {k: v for k, v in result.items() if k != 'unmatched'}
    report['copied']['unmatched'] = len(result.get('unmatched') or [])
    sb('sync_settings?on_conflict=key', 'POST',
       {'key': 'products_pull', 'value': result, 'updated_at': now_iso()},
       prefer='resolution=merge-duplicates,return=minimal')


def main():
    if not (SUPABASE_URL and SERVICE_KEY and WEBFLOW_TOKEN):
        report['warnings'].append(
            'missing SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY or '
            'WEBFLOW_API_TOKEN; nothing changed')
        finish(0)
    try:
        changes = sb('rpc/product_changes_to_apply', method='POST',
                     body={'p_limit': 30}) or []
        due = bool(sb('rpc/products_pull_due', method='POST', body={}))
    except Exception as e:  # noqa: BLE001
        # The first run after the upload can land before the build has
        # applied migration 131.
        report['warnings'].append(f'products read: {str(e)[:200]}')
        finish(0)
    report['to_write'] = len(changes)
    if not changes and not due:
        finish(0)   # the common case
    if changes:
        try:
            refs()
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f'webflow categories and currencies: {str(e)[:200]}')
            finish(1)
        write_changes(changes)
    if due:
        try:
            copy_from_webflow()
        except Exception as e:  # noqa: BLE001
            report['warnings'].append(f'products copy: {str(e)[:200]}')
    finish(1 if report['errors'] else 0)


if __name__ == '__main__':
    main()
