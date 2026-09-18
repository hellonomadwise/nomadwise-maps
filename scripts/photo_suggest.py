#!/usr/bin/env python3
"""Photo suggestions for spaces queued for nomadwise.io.

For every queued, not yet approved space that has no suggestions yet:
  1. take the place's Google photo names from the nightly snapshot
     (free; one Details call only when the snapshot has none) and the
     approved community photos nomads uploaded in the app;
  2. resolve each Google photo to its plain image link (the same
     lh3.googleusercontent.com address the founder used to copy by
     hand), paying one Photo media call only for links the venue does
     not already hold; the links are kept on the venue
     (google_photo_urls) so the app shows them for free afterwards;
  3. score every candidate against a written brief of what a listing
     photo should show (the room, seating, the front, people working)
     and should not (food close-ups, a lone drink, menus, selfies),
     plus the founder's own taste learned from earlier picks;
  4. save the candidates on the venue, and when the founder has not
     pasted anything yet, pre-fill the page's photos with the best
     five, flagged as suggested. Approve stays the gate.

`--learn` (nightly) turns the founder's picks and skips into a taste
vector that nudges future scores. Best-effort throughout: any failure
leaves the space exactly as it was and the founder can still paste.

`--learn` also resolves links for a slice of the existing venues each
night (the backlog), so map cards and space pages stop paying too.

Cost: at most six Photo media calls per space, once, and none when
the venue's links are already known. Scoring runs locally (CLIP,
open weights); no API.
"""
import datetime
import io
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
PLACES_KEY = os.environ.get('GOOGLE_PLACES_KEY', '')
LEARN = '--learn' in sys.argv

MAX_GOOGLE = 10       # Google returns at most ten photos per place
SUGGEST = 5           # the page takes five
MIN_SUGGEST = 3       # the app refuses Approve below three
GOOD = 0.30           # "shows the space" probability to count as good

# The brief. Positive prompts describe what a listing photo is for;
# negative ones what the founder keeps skipping. CLIP compares each
# photo with every sentence; the share of belief landing on the
# positive side is the base score.
POSITIVE = [
    'the interior of a cafe with tables, chairs and seating',
    'the interior of a coworking space with desks and chairs',
    'a bright room where people are working on laptops',
    'the front entrance and facade of a cafe or coworking space',
    'an outdoor terrace or garden seating area of a cafe',
    'a coffee on a table in a cafe with the room visible behind it',
    'a lounge or common area of a coliving space',
]
NEGATIVE = [
    'a close-up photo of food on a plate',
    'a close-up photo of a cup of coffee or a drink',
    'a close-up of pastries or cakes in a display case',
    'a menu or price list',
    'a selfie or a portrait of a person looking at the camera',
    'a logo, sign or text graphic',
    'a blurry or very dark photo',
]
TASTE_WEIGHT = 1.0    # how much the learned taste vector moves scores

report = {'started': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'spaces': 0, 'suggested': 0, 'errors': []}


def finish(code=0):
    report['finished'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    os.makedirs('ci-debug', exist_ok=True)
    with open('ci-debug/photo_suggest_report.json', 'w') as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report, indent=2))
    sys.exit(code)


if not (SUPABASE_URL and SERVICE_KEY):
    report['errors'].append('missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY')
    finish(0)


# ---------------------------------------------------------------- http
def _call(url, headers, method='GET', body=None, raw=False, retries=3):
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    url, data=data, method=method, headers=headers),
                    timeout=60) as r:
                blob = r.read()
                if raw:
                    return blob
                txt = blob.decode()
                return json.loads(txt) if txt else None
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries - 1:
                time.sleep(int(e.headers.get('Retry-After', '10')) + 1)
                continue
            raise


def sb(path, method='GET', body=None, prefer=None):
    headers = {'apikey': SERVICE_KEY,
               'Authorization': f'Bearer {SERVICE_KEY}',
               'Content-Type': 'application/json'}
    if prefer:
        headers['Prefer'] = prefer
    return _call(f'{SUPABASE_URL}/rest/v1/{path}', headers, method, body)


def google(path, params=None, mask=None):
    url = 'https://places.googleapis.com/v1/' + path
    if params:
        url += '?' + urllib.parse.urlencode(params)
    headers = {'X-Goog-Api-Key': PLACES_KEY}
    if mask:
        headers['X-Goog-FieldMask'] = mask
    return _call(url, headers)


def fetch_bytes(url):
    return _call(url, {'User-Agent': 'nomadmaps-photos'}, raw=True)


def thumb_of(uri):
    """A smaller copy of an lh3 link for scoring and thumbnails: the
    size lives in the =s... suffix, which the CDN honours for free."""
    if 'googleusercontent.com' in uri and '=' in uri.rsplit('/', 1)[-1]:
        base = uri.rsplit('=', 1)[0]
        return base + '=s512'
    return uri


# --------------------------------------------------------------- model
_model = None


def ensure_model():
    """CLIP ViT-B/32, installed on first use (cached between runs by
    the workflow). Returns (encode_images, encode_texts) or None."""
    global _model
    if _model is not None:
        return _model
    try:
        import torch  # noqa: F401
        import open_clip  # noqa: F401
    except ImportError:
        try:
            subprocess.run(
                [sys.executable, '-m', 'pip', 'install', '--quiet',
                 'torch', '--index-url',
                 'https://download.pytorch.org/whl/cpu'],
                check=True, timeout=900)
            subprocess.run(
                [sys.executable, '-m', 'pip', 'install', '--quiet',
                 'open_clip_torch', 'pillow'],
                check=True, timeout=900)
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f'model install failed: {e}')
            return None
        # Packages installed a moment ago land in the user site folder,
        # which was not on the path when this process started.
        import importlib
        import site
        for d in (site.getusersitepackages(), *site.getsitepackages()):
            if d and os.path.isdir(d) and d not in sys.path:
                sys.path.append(d)
        importlib.invalidate_caches()
    try:
        import torch
        import open_clip
        from PIL import Image
        model, _, preprocess = open_clip.create_model_and_transforms(
            'ViT-B-32', pretrained='openai')
        tokenizer = open_clip.get_tokenizer('ViT-B-32')
        model.eval()

        def encode_images(blobs):
            ims = []
            for b in blobs:
                ims.append(preprocess(Image.open(io.BytesIO(b)).convert('RGB')))
            with torch.no_grad():
                x = model.encode_image(torch.stack(ims))
                x = x / x.norm(dim=-1, keepdim=True)
            return x.tolist()

        def encode_texts(texts):
            with torch.no_grad():
                t = model.encode_text(tokenizer(texts))
                t = t / t.norm(dim=-1, keepdim=True)
            return t.tolist()

        _model = (encode_images, encode_texts)
        return _model
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'model load failed: {e}')
        return None


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def softmax(xs):
    import math
    m = max(xs)
    es = [math.exp(x - m) for x in xs]
    s = sum(es)
    return [e / s for e in es]


def score(img, prompts, taste):
    """Base score = belief that the photo is one of the positive kinds;
    label = the single best-matching sentence, for the app to show."""
    sims = [dot(img, p) * 100 for p in prompts]
    probs = softmax(sims)
    n_pos = len(POSITIVE)
    base = sum(probs[:n_pos])
    best = max(range(len(prompts)), key=lambda i: probs[i])
    label = (POSITIVE + NEGATIVE)[best]
    bonus = TASTE_WEIGHT * dot(img, taste) if taste else 0.0
    return base, base + bonus, label, best < n_pos


def taste_vector():
    try:
        rows = sb("sync_settings?key=eq.photo_taste&select=value")
        if rows and rows[0].get('value'):
            return rows[0]['value'].get('vector')
    except Exception:  # noqa: BLE001
        pass
    return None


# --------------------------------------------------------------- learn
def learn():
    """Founder's picks and skips -> a direction in embedding space.
    Stored under sync_settings.photo_taste; used as a score bonus."""
    try:
        picks = sb('photo_picks?select=uri,picked&limit=5000')
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'picks read: {e}')
        return
    if not picks:
        report['taste'] = 'no picks yet'
        return
    uris = sorted({p['uri'] for p in picks})
    embs = {}
    for i in range(0, len(uris), 100):
        chunk = uris[i:i + 100]
        q = ','.join('"' + u.replace('"', '') + '"' for u in chunk)
        try:
            for r in sb(f'photo_embeddings?uri=in.({q})&select=uri,embedding') or []:
                embs[r['uri']] = r['embedding']
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f'embeddings read: {e}')
            return
    picked = [embs[p['uri']] for p in picks if p['picked'] and p['uri'] in embs]
    skipped = [embs[p['uri']] for p in picks if not p['picked'] and p['uri'] in embs]
    if len(picked) < 10 or len(skipped) < 10:
        report['taste'] = f'not enough yet ({len(picked)} picked, {len(skipped)} skipped)'
        return
    dim = len(picked[0])
    mp = [sum(e[i] for e in picked) / len(picked) for i in range(dim)]
    ms = [sum(e[i] for e in skipped) / len(skipped) for i in range(dim)]
    v = [a - b for a, b in zip(mp, ms)]
    norm = sum(x * x for x in v) ** 0.5 or 1.0
    v = [round(x / norm, 5) for x in v]
    sb('sync_settings?on_conflict=key', method='POST',
       body=[{'key': 'photo_taste',
              'value': {'vector': v, 'picked': len(picked), 'skipped': len(skipped)},
              'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}],
       prefer='resolution=merge-duplicates,return=minimal')
    report['taste'] = f'updated from {len(picked)} picked, {len(skipped)} skipped'


# ------------------------------------------------------------- suggest
def resolve_names(v, names):
    """Photo names -> plain links, using what the venue already holds
    and paying (one media call) only for the rest. Saves new links on
    the venue so nothing is paid for twice."""
    known = dict(v.get('google_photo_urls') or {})
    fresh = {}
    for name in names:
        if name in known:
            continue
        try:
            m = google(f'{name}/media',
                       {'maxWidthPx': 1600, 'maxHeightPx': 1600,
                        'skipHttpRedirect': 'true'}) or {}
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f"{v.get('name')}: media {e}")
            continue
        uri = m.get('photoUri')
        if uri:
            fresh[name] = uri
        time.sleep(0.2)
    if fresh:
        known.update(fresh)
        try:
            sb(f"venues?id=eq.{v['id']}", method='PATCH',
               body={'google_photo_urls': known}, prefer='return=minimal')
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f"{v.get('name')}: links save {e}")
        report['photos_resolved'] = report.get('photos_resolved', 0) + len(fresh)
    return [known[n] for n in names if n in known]


def candidates_for(v):
    """Google photos (plain links) then community photos. The names
    come from the nightly snapshot when it has them (free), else from
    one Details call. Each: {uri, thumb, source}."""
    out = []
    snap = v.get('photos') or ((v.get('g_details') or {}).get('photos') or [])
    names = [p.get('name') for p in snap if p.get('name')]
    pid = v.get('google_place_id')
    if not names and pid and PLACES_KEY:
        try:
            d = google(f'places/{pid}', mask='photos') or {}
            names = [p.get('name') for p in (d.get('photos') or [])[:MAX_GOOGLE]
                     if p.get('name')]
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f"{v.get('name')}: details {e}")
    if names and PLACES_KEY:
        for uri in resolve_names(v, names[:MAX_GOOGLE]):
            out.append({'uri': uri, 'thumb': thumb_of(uri), 'source': 'google'})
    try:
        rows = sb(f"venue_photos?venue_id=eq.{v['id']}"
                  '&select=photo_path&order=verified_at.asc&limit=10') or []
        for r in rows:
            if r.get('photo_path'):
                uri = (f'{SUPABASE_URL}/storage/v1/object/public/'
                       f"submission-photos/{r['photo_path']}")
                out.append({'uri': uri, 'thumb': uri, 'source': 'community'})
    except Exception:  # noqa: BLE001
        pass
    seen, uniq = set(), []
    for c in out:
        if c['uri'] not in seen:
            seen.add(c['uri'])
            uniq.append(c)
    return uniq


def suggest():
    try:
        todo = sb('venues?website_status=eq.queued&website_approved_at=is.null'
                  '&website_photo_candidates=is.null'
                  '&select=id,name,google_place_id,website_photos,'
                  'google_photo_urls,photos:g_details->photos'
                  '&order=created_at.asc&limit=20') or []
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'venues read: {e}')
        return
    report['spaces'] = len(todo)
    if not todo:
        return
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    model = ensure_model()
    prompts = model[1](POSITIVE + NEGATIVE) if model else None
    taste = taste_vector() if model else None

    for v in todo:
        cands = candidates_for(v)
        if not cands:
            # Nothing to offer; remember we looked so it is not retried
            # every ten minutes. Edit -> Refresh clears it.
            sb(f"venues?id=eq.{v['id']}", method='PATCH',
               body={'website_photo_candidates': [],
                     'website_photo_candidates_at': now},
               prefer='return=minimal')
            continue

        scored = []
        if model:
            blobs, keep = [], []
            for c in cands:
                try:
                    blobs.append(fetch_bytes(c['thumb']))
                    keep.append(c)
                except Exception as e:  # noqa: BLE001
                    report['errors'].append(f"{v.get('name')}: fetch {e}")
            try:
                embs = model[0](blobs) if blobs else []
            except Exception as e:  # noqa: BLE001
                report['errors'].append(f"{v.get('name')}: encode {e}")
                embs = []
            rows = []
            for c, e in zip(keep, embs):
                base, total, label, good = score(e, prompts, taste)
                c = dict(c, score=round(total, 3), base=round(base, 3),
                         label=label, good=good)
                scored.append(c)
                rows.append({'uri': c['uri'], 'venue_id': v['id'],
                             'embedding': [round(x, 4) for x in e],
                             'label': label, 'base': round(base, 3)})
            if rows:
                try:
                    sb('photo_embeddings?on_conflict=uri', method='POST',
                       body=rows,
                       prefer='resolution=merge-duplicates,return=minimal')
                except Exception as e:  # noqa: BLE001
                    report['errors'].append(f'embeddings write: {e}')
        if not scored:
            # No scoring available: Google's own order is a fair guess
            # (the first photos are usually the owner's or the most
            # viewed), community photos after.
            for i, c in enumerate(cands):
                scored.append(dict(c, score=round(1.0 - i * 0.05, 3),
                                   base=None, label=None, good=True))

        ranked = sorted(scored, key=lambda c: -c['score'])
        chosen = [c for c in ranked if c.get('good')][:SUGGEST]
        if len(chosen) < MIN_SUGGEST:
            for c in ranked:
                if c not in chosen:
                    chosen.append(c)
                if len(chosen) >= MIN_SUGGEST:
                    break
        chosen_uris = {c['uri'] for c in chosen}
        for c in ranked:
            c['suggested'] = c['uri'] in chosen_uris

        pasted = [u for u in (v.get('website_photos') or [])
                  if str(u).startswith('http')]
        patch = {'website_photo_candidates': ranked,
                 'website_photo_candidates_at': now}
        if not pasted and chosen:
            # Pre-fill the page's photos; the founder sees them on the
            # card, flagged as suggested, and Approve confirms them.
            patch['website_photos'] = [c['uri'] for c in chosen]
            patch['website_photos_auto'] = True
            report['suggested'] += 1
        try:
            sb(f"venues?id=eq.{v['id']}", method='PATCH', body=patch,
               prefer='return=minimal')
        except Exception as e:  # noqa: BLE001
            report['errors'].append(f"{v.get('name')}: save {e}")


# Existing venues get free photo links a slice a night. Off (0) while
# the app has no real traffic: photo views cost nothing at that scale
# and the free photo calls are better spent on the website pipeline.
# 150 a night clears the backlog in about five nights for about $20;
# 30 a night stays inside the free allowance and takes a few months.
RESOLVE_PER_NIGHT = 0


def resolve_backlog():
    """Give every venue on the map free photo links, a slice a night.
    Venues whose snapshot has photos but whose links are missing."""
    if not PLACES_KEY or RESOLVE_PER_NIGHT <= 0:
        report['backlog_venues'] = 'off'
        return
    try:
        rows = sb('venues?google_photo_urls=is.null&g_details=not.is.null'
                  '&select=id,name,google_photo_urls,photos:g_details->photos'
                  f'&order=created_at.desc&limit={RESOLVE_PER_NIGHT}') or []
    except Exception as e:  # noqa: BLE001
        report['errors'].append(f'backlog read: {e}')
        return
    done = 0
    for v in rows:
        names = [p.get('name') for p in (v.get('photos') or []) if p.get('name')]
        if not names:
            # Nothing to resolve; mark so it is not re-read every night.
            sb(f"venues?id=eq.{v['id']}", method='PATCH',
               body={'google_photo_urls': {}}, prefer='return=minimal')
            continue
        resolve_names(v, names[:6])
        done += 1
    report['backlog_venues'] = done


if LEARN:
    learn()
    resolve_backlog()
suggest()
finish(0)
