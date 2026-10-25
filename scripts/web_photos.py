"""Photos for nomadwise.io: WebP, at most 90 KB, and still sharp.

Every photo Nomad Maps hands to Webflow goes through web_photo() first.
It downloads the picture (a Google photo, a phone upload, or a file
already on the site), makes a WebP copy and stores it in the public
"web-photos" folder in Supabase, and returns that copy's link, which
is what Webflow is given. Webflow copies the file in exactly as it is,
so the page gets the small WebP.

Quality comes first, size second. A smaller picture that is crisp looks
far better than a big one squeezed into blotches, so the size is made
to fit by reducing the pixels, never by dropping the quality below a
floor:

  * The picture is tried at widths from 1280 pixels down to 800 (a
    phone shows listing photos the full width of the screen, about
    1,170 real pixels), and at each width the highest quality that
    still fits in 90 KB is found.
  * The first (largest) size that fits at GOOD quality (80 of 100,
    where WebP is visually clean) wins.
  * If no size gets there, the largest size that fits at OK quality
    (72) is used.
  * If even 800 pixels wide at quality 72 does not fit (a rare, very busy
    photo), that version is used anyway and the report says it is a
    little over 90 KB. The floor is never broken to save a few KB.

A copy is named after the page and the original link, so the same
photo is converted once and reused after that.

Run directly to try it on files or links (nothing is uploaded):
    python3 scripts/web_photos.py photo.jpg https://...
"""
import hashlib
import io
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

LIMIT = 90_000          # bytes: under 90 KB however it is counted
GOOD_Q = 80             # visually clean WebP
OK_Q = 72               # the floor; never lower
TOP_Q = 88              # no point going higher for a web page
SIZES = (1280, 1200, 1100, 1000, 920, 860, 800)   # widths
BUCKET = 'web-photos'
VERSION = 'w1'          # bump to make every photo convert again

_pil = None


def _pillow():
    """Pillow, installed on first use on the GitHub runner."""
    global _pil
    if _pil:
        return _pil
    try:
        from PIL import Image, ImageOps  # noqa: F401
    except ImportError:
        base = [sys.executable, '-m', 'pip', 'install', '--quiet', 'pillow']
        for extra in ([], ['--user'], ['--user', '--break-system-packages']):
            if subprocess.run(base + extra, timeout=600).returncode == 0:
                break
        import importlib
        import site
        for d in (site.getusersitepackages(), *site.getsitepackages()):
            if d and os.path.isdir(d) and d not in sys.path:
                sys.path.append(d)
        importlib.invalidate_caches()
    from PIL import Image, ImageOps
    _pil = (Image, ImageOps)
    return _pil


def _webp(im, q, method):
    buf = io.BytesIO()
    im.save(buf, 'WEBP', quality=q, method=method)
    return buf.getvalue()


def _best_q(im):
    """Highest quality from OK_Q to TOP_Q that fits LIMIT at this size,
    with its bytes; (None, smallest bytes) when even OK_Q is too big.
    Searched with the fast encoder (method 4)."""
    low = _webp(im, OK_Q, 4)
    if len(low) > LIMIT:
        return None, low
    lo, hi, best = OK_Q, TOP_Q, (OK_Q, low)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        b = _webp(im, mid, 4)
        if len(b) <= LIMIT:
            lo, best = mid, (mid, b)
        else:
            hi = mid - 1
    return best


def encode(raw):
    """Picture bytes in, (WebP bytes, facts) out."""
    Image, ImageOps = _pillow()
    im = Image.open(io.BytesIO(raw))
    im = ImageOps.exif_transpose(im)
    if im.mode in ('RGBA', 'LA', 'P'):
        im = im.convert('RGBA')
        flat = Image.new('RGB', im.size, (255, 255, 255))
        flat.paste(im, mask=im.split()[-1])
        im = flat
    elif im.mode != 'RGB':
        im = im.convert('RGB')
    w, h = im.size
    # Sized by width: on a phone the page shows the photo the full
    # width of the screen (about 1,170 real pixels on an iPhone), and
    # tall photos are cropped to a wide band, so width is what shows.
    sizes = [s for s in SIZES if s < w]
    if w <= SIZES[0]:
        sizes = [w] + sizes
    sizes = sizes or [w]

    def at(s):
        if s == w:
            return im
        return im.resize((s, max(1, round(h * s / w))), Image.LANCZOS)

    tried = []
    for s in sizes:
        small = at(s)
        q, b = _best_q(small)
        tried.append((s, q, small, b))
        if q is not None and q >= GOOD_Q:
            break
    pick = next(((s, q, sm) for s, q, sm, _ in tried
                 if q is not None and q >= GOOD_Q), None) \
        or next(((s, q, sm) for s, q, sm, _ in tried if q is not None),
                None)
    over = False
    if pick is None:
        # Even the smallest size is over at the floor: keep the floor.
        s, _, sm, _ = tried[-1]
        pick, over = (s, OK_Q, sm), True
    s, q, sm = pick
    out = _webp(sm, q, 6)               # the slow, smaller encoder
    if len(out) > LIMIT and not over:   # (very rarely bigger than 4)
        out = _webp(sm, q, 4)
    return out, {'width': sm.size[0], 'height': sm.size[1], 'quality': q,
                 'kb': round(len(out) / 1000, 1), 'over_limit': over,
                 'source_kb': round(len(raw) / 1000, 1),
                 'source_size': f'{w}x{h}'}


def _get(url, timeout=40):
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0 (NomadMaps photo prep)'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read(30_000_001)
    if len(data) > 30_000_000:
        raise ValueError('photo over 30 MB')
    return data


def _slug(text):
    t = re.sub(r'[^a-z0-9]+', '-', (text or '').lower()).strip('-')
    return t[:60] or 'photo'


class WebPhotos:
    """Converts photo links for Webflow and keeps a log for the report.

    sb_url and key are the Supabase project and its service key. Any
    failure leaves the original link in place (the page still gets its
    photo) and is listed in .log so it can be seen and redone."""

    def __init__(self, sb_url, key):
        self.sb_url = sb_url.rstrip('/')
        self.key = key
        self.log = []
        self._bucket_ok = False
        self._done = {}

    def _auth(self, extra=None):
        h = {'apikey': self.key, 'Authorization': f'Bearer {self.key}'}
        h.update(extra or {})
        return h

    def _ensure_bucket(self):
        if self._bucket_ok:
            return
        body = (f'{{"id":"{BUCKET}","name":"{BUCKET}","public":true}}'
                ).encode()
        try:
            urllib.request.urlopen(urllib.request.Request(
                f'{self.sb_url}/storage/v1/bucket', data=body,
                method='POST', headers=self._auth(
                    {'Content-Type': 'application/json'})), timeout=30)
        except urllib.error.HTTPError as e:
            if e.code not in (400, 409):   # 400/409: it exists already
                raise
        self._bucket_ok = True

    def public(self, path):
        return f'{self.sb_url}/storage/v1/object/public/{BUCKET}/{path}'

    def is_web_ready(self, url):
        """A link this module made (already WebP and checked)."""
        return f'/object/public/{BUCKET}/' in str(url)

    def convert(self, url, hint=''):
        """The WebP link to give Webflow for this photo. Never raises."""
        url = str(url or '').strip()
        if not url.startswith('http') or self.is_web_ready(url):
            return url
        if url in self._done:
            return self._done[url]
        h = hashlib.sha1(f'{VERSION}|{url}'.encode()).hexdigest()[:10]
        path = f'{_slug(hint)}-{h}.webp'
        link = self.public(path)
        try:
            # Converted before (same page, same original): reuse it.
            try:
                urllib.request.urlopen(urllib.request.Request(
                    link, method='HEAD'), timeout=20)
                self._done[url] = link
                return link
            except urllib.error.HTTPError:
                pass
            raw = _get(url)
            out, facts = encode(raw)
            self._ensure_bucket()
            urllib.request.urlopen(urllib.request.Request(
                f'{self.sb_url}/storage/v1/object/{BUCKET}/{path}',
                data=out, method='POST', headers=self._auth({
                    'Content-Type': 'image/webp',
                    'Cache-Control': 'max-age=31536000',
                    'x-upsert': 'true'})), timeout=60)
            facts.update({'from': url[:120], 'to': link})
            self.log.append(facts)
            self._done[url] = link
            return link
        except Exception as e:  # noqa: BLE001
            self.log.append({'from': url[:120], 'error': str(e)[:200],
                             'kept_original': True})
            return url


if __name__ == '__main__':
    for arg in sys.argv[1:]:
        raw = _get(arg) if arg.startswith('http') else open(arg, 'rb').read()
        out, facts = encode(raw)
        name = os.path.splitext(os.path.basename(arg.split('?')[0]))[0]
        dest = f'{name}.webp'
        with open(dest, 'wb') as f:
            f.write(out)
        print(dest, facts)
