#!/usr/bin/env python3
"""
Enquiries from the nomadwise.io pop-up -> Nomad Maps (migration 113).

The Send an enquiry pop-up on the listing pages is a Webflow form
("Research Form"). Webflow emails each one to hello@nomadwise.io and
keeps it; this reads them over the Webflow API and files each one in
the enquiries table through import_webflow_enquiry(), which decides
where it goes: straight to a Verified space, or into "Enquiries to pass
on" in the control centre (with a phone ping).

Then, for every space with an enquiry waiting, it looks for an email
address on the space's own website (the home page and its contact
page) and stores what it finds on the venue, so the Pass on box can
suggest it. Only the space's own website is read, a handful of pages
at most, once per space.

Runs inside the ten-minute website push. Needs SUPABASE_URL,
SUPABASE_SERVICE_ROLE_KEY and WEBFLOW_API_TOKEN (with Forms: read).
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

SITE_ID = '64b6780f84d27e4bfd91f236'
# The pop-up form on the Coworking template (Webflow's element id; the
# form's own id changes with every publish, this one does not).
FORM_ELEMENT_ID = '969a5db0-5224-a7b6-8a5e-1c5fadb9567a'

report = {'started': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'read': 0, 'filed': {}, 'contacts_checked': 0, 'contacts_found': 0,
          'errors': [], 'warnings': []}


def finish(code=0):
    print(json.dumps(report, indent=2, default=str))
    # The control centre shows when the pop-up was last read and any
    # problem (sync_settings 'enquiry_import').
    if SUPABASE_URL and SERVICE_KEY:
        try:
            sb('sync_settings?on_conflict=key', 'POST',
               {'key': 'enquiry_import',
                'value': {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                          'read': report['read'], 'filed': report['filed'],
                          'outreach': report.get('outreach', {}),
                          'outreach_other_forms': report.get('outreach_other_forms', {}),
                          'errors': (report['errors'] + report['warnings'])[:3]},
                'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat()},
               prefer='resolution=merge-duplicates,return=minimal')
        except Exception as e:  # noqa: BLE001
            print(f'status note: {e}')
    sys.exit(code)


if not (SUPABASE_URL and SERVICE_KEY):
    report['warnings'].append('SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY missing; nothing to do')
    finish(0)


def _call(url, headers, method='GET', body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    url, data=data, method=method, headers=headers),
                    timeout=timeout) as r:
                txt = r.read().decode()
                return json.loads(txt) if txt else None
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 2:
                time.sleep(5)
                continue
            raise RuntimeError(f'{e.code} {e.read().decode()[:300]}') from None


def sb(path, method='GET', body=None, prefer=None):
    headers = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
               'Content-Type': 'application/json'}
    if prefer:
        headers['Prefer'] = prefer
    return _call(f'{SUPABASE_URL}/rest/v1/{path}', headers, method, body)


def wf(path, params=None):
    url = 'https://api.webflow.com/v2' + path
    if params:
        url += '?' + urllib.parse.urlencode(params)
    return _call(url, {'Authorization': f'Bearer {WEBFLOW_TOKEN}',
                       'accept': 'application/json'})


# ------------------------------------------------------------- import
def field(resp, *names):
    """The form's fields by their Webflow names, tolerant of renames."""
    for n in names:
        if n in resp and resp[n] is not None:
            return str(resp[n])
    low = {k.lower(): v for k, v in resp.items()}
    for n in names:
        for k, v in low.items():
            if n.lower().split()[0] in k and v is not None:
                return str(v)
    return ''


if not WEBFLOW_TOKEN:
    report['warnings'].append('WEBFLOW_API_TOKEN not set; pop-up enquiries not read')
else:
    # What is already filed, so only new submissions cost a call. The
    # whole list is read each time (100 a page), whatever order Webflow
    # returns it in.
    known = set()
    try:
        offset_k = 0
        while True:
            rows = sb('enquiries?webflow_submission_id=not.is.null'
                      f'&select=webflow_submission_id&order=created_at&limit=1000&offset={offset_k}') or []
            known.update(r['webflow_submission_id'] for r in rows)
            if len(rows) < 1000:
                break
            offset_k += 1000
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'known read: {str(e)[:200]}')
    offset, invalid = 0, 0
    popup_ids = set()  # every pop-up submission seen, so Outreach skips them
    while offset < 5000:
        try:
            page = wf(f'/sites/{SITE_ID}/form_submissions',
                      {'elementId': FORM_ELEMENT_ID, 'limit': 100, 'offset': offset})
        except Exception as e:  # noqa: BLE001
            msg = str(e)
            if msg.startswith('403') or msg.startswith('401'):
                report['errors'].append(
                    'Webflow refused to list form submissions: the API token '
                    'needs the "Forms: read" permission. ' + msg[:160])
            else:
                report['errors'].append(f'form submissions: {msg[:200]}')
            break
        subs = (page or {}).get('formSubmissions') or []
        for s_ in subs:
            report['read'] += 1
            popup_ids.add(s_.get('id'))
            if s_.get('id') in known:
                report['filed']['known'] = report['filed'].get('known', 0) + 1
                continue
            r = s_.get('formResponse') or {}
            payload = {
                'id': s_.get('id'),
                'submitted_at': s_.get('dateSubmitted'),
                'listing': field(r, 'Listing'),
                'message': field(r, 'Text area', 'Message'),
                'name': field(r, 'Name Of Customer 2', 'Name'),
                'email': field(r, 'Email Of Customer 2', 'Email'),
                'phone': field(r, 'Contact Number 3', 'Contact Number', 'Phone'),
                'marketing': field(r, 'Agree To Receive Marketing 2', 'Marketing'),
            }
            try:
                res = sb('rpc/import_webflow_enquiry', 'POST', {'p': payload})
            except Exception as e:  # noqa: BLE001
                report['errors'].append(f"file {s_.get('id')}: {str(e)[:200]}")
                continue
            res = res if isinstance(res, str) else str(res)
            report['filed'][res] = report['filed'].get(res, 0) + 1
            if res == 'invalid':
                invalid += 1
        total = ((page or {}).get('pagination') or {}).get('total') or 0
        offset += 100
        if len(subs) < 100 or offset >= total:
            break
    new_ones = report['read'] - report['filed'].get('known', 0)
    if new_ones >= 3 and invalid == new_ones:
        report['errors'].append(
            f'All {invalid} new pop-up submissions had no usable email; the '
            'form fields may have been renamed in Webflow.')


# ------------------------------------------------ business forms -> Outreach
# The other forms on nomadwise.io (Add Coworking Space, Add Cafe,
# Recommendations from Users, Contact) are spaces asking to be listed.
# Each submission becomes a contact in the control centre's Outreach
# list (migration 121), once; the pop-up enquiry form is handled above.
if WEBFLOW_TOKEN:
    known_o = set()
    try:
        offset_k = 0
        while True:
            rows = sb('outreach_messages?source_ref=like.wf:*'
                      f'&select=source_ref&order=at&limit=1000&offset={offset_k}') or []
            known_o.update(r['source_ref'] for r in rows)
            if len(rows) < 1000:
                break
            offset_k += 1000
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'outreach known read: {str(e)[:200]}')
    offset = 0
    outreach = {}
    skipped_forms = {}
    OUTREACH_FORM_WORDS = ('business', 'cowork', 'cafe', 'coliving', 'space',
                           'recommend', 'listing', 'list my', 'add my')
    while offset < 5000:
        try:
            page = wf(f'/sites/{SITE_ID}/form_submissions', {'limit': 100, 'offset': offset})
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f'all form submissions: {str(e)[:200]}')
            break
        subs = (page or {}).get('formSubmissions') or []
        for s_ in subs:
            form_name = (s_.get('displayName') or s_.get('formName') or '').strip()
            low = form_name.lower()
            # The pop-up is a nomad writing to a space, filed above, and
            # never a contact here.
            if (FORM_ELEMENT_ID in (s_.get('elementId'), s_.get('formElementId'))
                    or s_.get('id') in popup_ids or s_.get('id') in known
                    or 'research' in low):
                continue
            # Only the forms a space fills in (or a nomad recommending
            # one). Anything else is counted by name so a renamed form
            # is noticed.
            if not any(w in low for w in OUTREACH_FORM_WORDS):
                skipped_forms[form_name or '(no name)'] = \
                    skipped_forms.get(form_name or '(no name)', 0) + 1
                continue
            if 'wf:' + str(s_.get('id')) in known_o:
                outreach['known'] = outreach.get('known', 0) + 1
                continue
            payload = {
                'id': s_.get('id'),
                'form_name': form_name,
                'submitted_at': s_.get('dateSubmitted'),
                'fields': s_.get('formResponse') or {},
            }
            try:
                res = sb('rpc/import_webflow_outreach', 'POST', {'p': payload})
            except Exception as e:  # noqa: BLE001
                report['errors'].append(f"outreach {s_.get('id')}: {str(e)[:200]}")
                continue
            res = res if isinstance(res, str) else str(res)
            outreach[res] = outreach.get(res, 0) + 1
        total = ((page or {}).get('pagination') or {}).get('total') or 0
        offset += 100
        if len(subs) < 100 or offset >= total:
            break
    report['outreach'] = outreach
    if skipped_forms:
        report['outreach_other_forms'] = skipped_forms


# ------------------------------------------------- contact suggestions
EMAIL_RE = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}')
SKIP_ENDINGS = ('.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.css', '.js', '.ico')
SKIP_DOMAINS = ('sentry.io', 'sentry-next.wixpress.com', 'wixpress.com', 'example.com',
                'domain.com', 'email.com', 'yourdomain.com', 'yoursite.com',
                'godaddy.com', 'squarespace.com', 'wordpress.com', 'mysite.com')
GOOD_PREFIXES = ('hello', 'info', 'contact', 'booking', 'bookings', 'reception',
                 'cowork', 'coworking', 'hola', 'ola', 'ciao', 'office', 'team')
CONTACT_WORDS = ('contact', 'kontakt', 'contacto', 'contato', 'contatti', 'impressum',
                 'imprint', 'about')
# Not the space's own site: nothing useful on their home page.
NOT_OWN_SITE = ('instagram.com', 'facebook.com', 'linktr.ee', 'wa.me', 'whatsapp.com',
                'google.com', 'goo.gl', 'booking.com', 'tripadvisor.com', 'airbnb.com',
                'coworker.com', 'tiktok.com', 'linkedin.com', 'x.com', 'twitter.com')
UA = 'Mozilla/5.0 (compatible; NomadwiseBot/1.0; +https://www.nomadwise.io)'


def fetch(url):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': UA,
                                                   'Accept': 'text/html'})
        with urllib.request.urlopen(req, timeout=10) as r:
            ctype = r.headers.get('Content-Type', '')
            if 'html' not in ctype and 'text' not in ctype:
                return ''
            return r.read(600_000).decode('utf-8', 'replace')
    except Exception:  # noqa: BLE001
        return ''


def site_root(website):
    w = (website or '').strip()
    if not w:
        return None
    if not w.startswith('http'):
        w = 'https://' + w
    p = urllib.parse.urlparse(w)
    if not p.netloc:
        return None
    return f'{p.scheme}://{p.netloc}'


def base_domain(host):
    host = (host or '').lower().split(':')[0]
    if host.startswith('www.'):
        host = host[4:]
    parts = host.split('.')
    return '.'.join(parts[-2:]) if len(parts) >= 2 else host


def emails_in(page):
    text = html.unescape(page).replace('%40', '@')
    text = re.sub(r'\s*\[\s*at\s*\]\s*', '@', text, flags=re.I)
    found = []
    for m in EMAIL_RE.findall(text):
        e = m.strip('.').lower()
        if e.endswith(SKIP_ENDINGS) or any(e.endswith('@' + d) or e.endswith('.' + d)
                                           for d in SKIP_DOMAINS):
            continue
        if e.split('@')[0] in ('noreply', 'no-reply', 'donotreply', 'user', 'name', 'email'):
            continue
        if e not in found:
            found.append(e)
    return found


def contact_links(page, root):
    links = []
    for href in re.findall(r'href=["\']([^"\'#]+)["\']', page, flags=re.I):
        h = href.strip()
        if h.lower().startswith(('mailto:', 'tel:', 'javascript:')):
            continue
        if any(w in h.lower() for w in CONTACT_WORDS):
            full = urllib.parse.urljoin(root + '/', h)
            if urllib.parse.urlparse(full).netloc == urllib.parse.urlparse(root).netloc \
                    and full not in links:
                links.append(full)
    return links[:3]


def rank(emails, domain):
    def score(e):
        local, _, dom = e.partition('@')
        s = 0
        if base_domain(dom) == domain:
            s -= 10
        if local in GOOD_PREFIXES or any(local.startswith(p) for p in GOOD_PREFIXES):
            s -= 3
        return s
    return sorted(emails, key=score)


try:
    waiting = sb('enquiries?status=eq.waiting&venue_id=not.is.null&select=venue_id') or []
    ids = sorted({w['venue_id'] for w in waiting})
    venues = []
    if ids:
        venues = sb('venues?id=in.(' + ','.join(ids) + ')'
                    '&contact_checked_at=is.null&select=id,name,website,contact_emails') or []
except Exception as e:  # noqa: BLE001
    report['errors'].append(f'waiting read: {str(e)[:200]}')
    venues = []

for v in venues[:10]:
    report['contacts_checked'] += 1
    root = site_root(v.get('website'))
    if root and base_domain(urllib.parse.urlparse(root).netloc) in NOT_OWN_SITE:
        root = None
    found = []
    if root:
        home = fetch(root)
        found += emails_in(home)
        for link in contact_links(home, root):
            found += [e for e in emails_in(fetch(link)) if e not in found]
            time.sleep(0.5)
        if not found:
            for path in ('/contact', '/contact-us', '/contacto', '/kontakt'):
                found += [e for e in emails_in(fetch(root + path)) if e not in found]
                if found:
                    break
        found = rank(found, base_domain(urllib.parse.urlparse(root).netloc))[:5]
    kept = list(v.get('contact_emails') or [])
    merged = kept + [e for e in found if e not in kept]
    if found:
        report['contacts_found'] += 1
    try:
        sb(f"venues?id=eq.{v['id']}", 'PATCH',
           {'contact_emails': merged or None,
            'contact_checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat()},
           prefer='return=minimal')
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f"contacts {v.get('name')}: {str(e)[:200]}")

finish(0)
