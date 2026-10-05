"""
Two kinds of evidence for the Candidates list (migration 140), run at
the end of the nightly job (scripts/enrich_venues.py):

  1. work_search(): asks Google's own search for "laptop friendly
     cafe" and "cafe to work from" in each city with a city page, and
     keeps which places come back. Google answers from all of a
     place's reviews and details, where the review scan only sees
     five reviews.

  2. check_mentions(): the places other sites and blogs name (loaded
     by a session, public.place_mentions) are matched to a place on
     Google, which also says whether it is still open. A closed place
     is marked closed and never becomes a candidate.

Both only read Google and write through the database's own functions.
Neither touches a space or the website. Anything that goes wrong is a
line in the log; the rest of the nightly job is never held up.

How much is asked is decided by the database, not here
(public.evidence_plan(), migration 140): which cities are worked on,
how many calls a night and a month, and how much of Google's free
monthly amount for this kind of call is left once the app and the
other jobs have had theirs. A run never makes more calls than the
plan gives it, and makes none when nothing is left.

The helpers of enrich_venues.py are passed in (req, the Supabase
address and headers, the Google key), so the same code runs in a test
against stand-ins.
"""
import math
import re
import time
import unicodedata
import urllib.error

# What is asked of Google for each city. Kept to two: every phrase is
# up to three calls a city.
PHRASES = ['laptop friendly cafe', 'cafe to work from']
PAGES_PER_PHRASE = 3          # 20 places a page
CALLS_A_CITY = len(PHRASES) * PAGES_PER_PHRASE
CITIES_PER_RUN = 10           # the plan's calls decide; this is a ceiling
CITY_RADIUS_M = 20000         # where Google is told to look first
CITY_REACH_KM = 45            # further than this is another city

MENTIONS_PER_RUN = 100        # one call each; the plan's calls decide
SAVE_EVERY = 10               # so a problem saving costs ten calls, not all

# Google's types for a place that is a cafe or a coworking space. The
# search for places to work also returns libraries, hotels and bars;
# found places are drawn on the map, which shows cafes and coworking.
CAFE_TYPES = {'cafe', 'coffee_shop', 'bakery', 'tea_house', 'internet_cafe',
              'cafeteria', 'brunch_restaurant', 'breakfast_restaurant',
              'coworking_space', 'dessert_shop', 'bagel_shop', 'juice_shop'}
# ... and the types that are plainly neither, whatever a list says.
NOT_A_CAFE = {'hotel', 'lodging', 'hostel', 'motel', 'resort_hotel',
              'bed_and_breakfast', 'guest_house', 'pub', 'bar', 'wine_bar',
              'night_club', 'library', 'museum', 'university', 'school',
              'gym', 'fitness_center', 'shopping_mall', 'department_store',
              'book_store', 'supermarket', 'art_gallery'}
COWORK_NAME = re.compile(
    r'cowork|co-work|co work|workspace|work ?space|work ?hub|wework', re.I)

# The fields asked for decide which kind of call Google counts it as.
# These keep it "Text Search Pro" (5,000 free a month). Asking for the
# rating as well would make it "Text Search Enterprise" (1,000 free),
# so the rating is left to the review scan, which reads it on a call
# it already makes. nextPageToken is free.
PLACE_FIELDS = ('places.id,places.displayName,places.location,'
                'places.primaryType,places.businessStatus,'
                'places.shortFormattedAddress')

SEARCH_URL = 'https://places.googleapis.com/v1/places:searchText'

# Words that do not tell one place from another.
GENERIC = {
    'the', 'and', 'of', 'at', 'in', 'cafe', 'coffee', 'coffeehouse',
    'house', 'shop', 'co', 'ltd', 'london', 'coworking', 'cowork',
    'space', 'spaces', 'office', 'offices', 'workspace', 'workspaces',
    'roasters', 'roastery', 'bar', 'kitchen', 'bakery', 'espresso',
}


class OutOfCalls(Exception):
    """The plan's calls for this run are used up."""


def _stops(e):
    """True when the error means: stop asking Google for this run. The
    plan's calls are used up, the day's spending limit is reached or
    the job is paused in the app (google_meter), or Google itself is
    refusing (a quota, a key, a bad request): asking again in the same
    run would only be refused again."""
    return (isinstance(e, OutOfCalls)
            or type(e).__name__ == 'DailyLimitReached'
            or isinstance(e, urllib.error.HTTPError))


def name_key(name):
    """A name as two sites would both write it (as public.mention_key)."""
    n = unicodedata.normalize('NFKD', name or '')
    n = n.encode('ascii', 'ignore').decode().lower().replace('&', ' and ')
    n = re.sub(r"['`.]", '', n)
    n = re.sub(r'[^a-z0-9]+', ' ', n).strip()
    return re.sub(r'^the\s+', '', n)


def _tokens(name):
    return set(name_key(name).split())


def same_place_name(wanted, found):
    """Is Google's name for a place the name a site wrote? True when
    the telling words of one are all in the other: "The Wren" and "The
    Wren Coffee", "Uncommon Borough" and "Uncommon Borough - Coworking
    & Office Space". "Second Home Spitalfields" is not "Second Home
    London Fields"."""
    a_all, b_all = _tokens(wanted), _tokens(found)
    if not a_all or not b_all:
        return False
    a = (a_all - GENERIC) or a_all
    b = (b_all - GENERIC) or b_all
    if a <= b_all:
        return True
    # Google's name is the shorter one ("Second Home" for "Second Home
    # Spitalfields"): only when it starts where the written name
    # starts, so "Notes Coffee Kings Cross" is not a place called
    # "Kings Cross".
    first = next((t for t in name_key(wanted).split() if t in a), None)
    return b <= a_all and first in b_all


def same_telling_words(wanted, found):
    """Stricter: the telling words are the same ("The Wren" and "The
    Wren Coffee", not "Grind" and "Shoreditch Grind")."""
    a_all, b_all = _tokens(wanted), _tokens(found)
    if not a_all or not b_all:
        return False
    return ((a_all - GENERIC) or a_all) == ((b_all - GENERIC) or b_all)


def _stem(name):
    """A name without what follows a dash, a bar or a comma."""
    return re.split(r'\s+[-\u2013\u2014|@]\s+|,\s', name or '')[0].strip()


def _km(lat1, lng1, lat2, lng2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    h = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2)
         * math.sin(math.radians(lng2 - lng1) / 2) ** 2)
    return 6371 * 2 * math.asin(min(1, math.sqrt(h)))


def _is_cafe_or_coworking(pl):
    name = (pl.get('displayName') or {}).get('text') or ''
    return (pl.get('primaryType') in CAFE_TYPES
            or bool(COWORK_NAME.search(name)))


def _row(pl):
    """A place as the database functions take it, or None."""
    loc = pl.get('location') or {}
    if not pl.get('id') or loc.get('latitude') is None \
            or loc.get('longitude') is None:
        return None
    return {
        'id': pl['id'],
        'name': (pl.get('displayName') or {}).get('text') or 'Unnamed',
        'lat': loc['latitude'],
        'lng': loc['longitude'],
        'primary_type': pl.get('primaryType'),
        'address': (pl.get('shortFormattedAddress') or '').strip() or None,
    }


class Evidence:
    def __init__(self, req, supabase_url, sb_headers, places_key,
                 pause=2.0, log=print, calls=0):
        self.req = req
        self.base = supabase_url.rstrip('/') + '/rest/v1/rpc/'
        self.sb_headers = sb_headers
        self.key = places_key
        self.pause = pause
        self.log = log
        # How many calls to Google this run may still make. None until
        # the plan is read; a run with no plan makes none.
        self.calls_left = calls
        self.calls_made = 0

    def read_plan(self):
        """Asks the database what this run may spend. False (and a
        line in the log saying why) when it may spend nothing."""
        try:
            plan = self.rpc('evidence_plan', {}) or {}
        except Exception as e:  # noqa: BLE001
            self.log(f'Evidence skipped (migration 140 not run yet?): {e}')
            return False
        self.calls_left = int(plan.get('left_run') or 0)
        used, month = plan.get('used_job'), plan.get('calls_per_month')
        everyone, free = plan.get('used_all'), plan.get('free_per_month')
        self.log(f"Evidence: {self.calls_left} calls this run. This month: "
                 f"{used} of {month} for this job; {everyone} of Google's "
                 f"{free} free ({plan.get('kind')}) used by everyone, "
                 f"{plan.get('keep_back')} kept back. Cities: "
                 f"{', '.join(plan.get('cities') or []) or 'none'}.")
        if self.calls_left <= 0:
            self.log('Evidence: nothing left to spend, so Google is not '
                     'asked.')
            return False
        return True

    def rpc(self, name, body):
        return self.req(self.base + name, method='POST',
                        headers=self.sb_headers(), body=body)

    def search(self, query, lat, lng, page_size=20, token=None,
               radius=CITY_RADIUS_M):
        body = {
            'textQuery': query,
            'pageSize': page_size,
            'locationBias': {'circle': {
                'center': {'latitude': lat, 'longitude': lng},
                'radius': radius,
            }},
        }
        if token:
            body['pageToken'] = token
        if self.calls_left <= 0:
            raise OutOfCalls("this run's calls are used up")
        self.calls_left -= 1
        self.calls_made += 1
        return self.req(SEARCH_URL, method='POST', headers={
            'X-Goog-Api-Key': self.key,
            'X-Goog-FieldMask': PLACE_FIELDS + ',nextPageToken',
            'Content-Type': 'application/json',
        }, body=body) or {}

    # ------------------------------------------------ 1. Google's search

    def work_search(self, cities=CITIES_PER_RUN):
        try:
            due = self.rpc('work_search_due', {'p_limit': cities}) or []
        except Exception as e:  # noqa: BLE001
            self.log(f'Work search skipped (migration 140 not run yet?): {e}')
            return
        done = 0
        for city in due:
            if self.calls_left < CALLS_A_CITY:
                # never half a city: it waits for a night with room
                self.log(f"Work search: {city.get('name')} waits, "
                         f'{self.calls_left} calls left.')
                break
            try:
                finished = self._one_city(city)
            except Exception as e:  # noqa: BLE001
                if _stops(e):
                    self.log(f'Work search stopped: {e}')
                    break
                self.log(f"Work search, {city.get('name')}: {e}")
                continue
            if not finished:
                break
            done += 1
        self.log(f'Work search: {done} of {len(due)} cities asked.')

    def _one_city(self, city):
        """Ask every phrase for one city and save. False when Google
        had to be left alone part-way (nothing is saved, so the city is
        asked again another night)."""
        lat, lng = city['lat'], city['lng']
        where = ', '.join(x for x in (city.get('name'), city.get('country'))
                          if x)
        found = {}
        calls = 0
        for phrase in PHRASES:
            token = None
            rank = 0
            for _ in range(PAGES_PER_PHRASE):
                try:
                    res = self.search(f'{phrase} in {where}', lat, lng,
                                      token=token)
                except Exception as e:  # noqa: BLE001
                    if _stops(e):
                        self.log(f'Work search stopped: {e}')
                        return False
                    raise
                calls += 1
                for pl in res.get('places') or []:
                    rank += 1
                    if pl.get('businessStatus') not in (None, 'OPERATIONAL'):
                        continue
                    if not _is_cafe_or_coworking(pl):
                        continue   # a library, a hotel, a bar
                    row = _row(pl)
                    if not row or _km(lat, lng, row['lat'],
                                      row['lng']) > CITY_REACH_KM:
                        continue
                    kept = found.setdefault(row['id'], dict(
                        row, phrases=[], rank=rank))
                    if phrase not in kept['phrases']:
                        kept['phrases'].append(phrase)
                    kept['rank'] = min(kept['rank'], rank)
                token = res.get('nextPageToken')
                if not token:
                    break
                time.sleep(self.pause)   # a page token needs a moment
        try:
            saved = self.rpc('record_work_search', {
                'p_region': city['region_id'], 'p_name': city.get('name'),
                'p_calls': calls, 'p_rows': list(found.values())})
        except Exception as e:  # noqa: BLE001
            # Paid for and not kept: do not go on to pay for more.
            self.log(f"Work search, {city.get('name')}: could not be "
                     f'saved, stopping: {e}')
            return False
        self.log(f"Work search, {city.get('name')}: {saved} places "
                 f'from {calls} calls.')
        return True

    # --------------------------------------- 2. what other sites name

    def check_mentions(self, limit=MENTIONS_PER_RUN):
        try:
            # Free first: names we already have (sweeps add places).
            self.rpc('mentions_match_local', {})
            due = self.rpc('mentions_due', {
                'p_limit': max(0, min(limit, self.calls_left))}) or []
        except Exception as e:  # noqa: BLE001
            self.log(f'Mentions skipped (migration 140 not run yet?): {e}')
            return
        counts = {}
        saved = 0
        batch = []

        def save():
            # Kept every few names: a problem saving costs a few
            # calls, and stops the run before it pays for more.
            nonlocal saved
            if not batch:
                return True
            try:
                self.rpc('record_mention_checks', {'p': list(batch)})
            except Exception as e:  # noqa: BLE001
                self.log(f'Mentions could not be saved, stopping: {e}')
                return False
            for r in batch:
                counts[r['status']] = counts.get(r['status'], 0) + 1
            saved += len(batch)
            batch.clear()
            return True

        for m in due:
            try:
                batch.append(self._one_mention(m))
            except Exception as e:  # noqa: BLE001
                if _stops(e):
                    self.log(f'Mentions stopped: {e}')
                    break
                # anything else: left waiting, asked again another night
                self.log(f"Mentions, {m.get('place')}: {e}")
                continue
            if len(batch) >= SAVE_EVERY and not save():
                return
        if not save():
            return
        self.log(f'Mentions: {saved} of {len(due)} names checked '
                 f'({counts}).')

    def _one_mention(self, m):
        """One named place: which place Google says it is, and whether
        it is open."""
        out = {'city': m['city'], 'name_key': m['name_key'],
               'kind': m.get('kind'), 'status': 'not_found'}
        area = (m.get('area') or '').strip()
        query = ', '.join(x for x in (m['place'], area, m['city']) if x)
        res = self.search(query, m['lat'], m['lng'], page_size=5)
        alike = []
        for pl in res.get('places') or []:
            row = _row(pl)
            if not row:
                continue
            if _km(m['lat'], m['lng'], row['lat'], row['lng']) > CITY_REACH_KM:
                continue
            # a pub or a hotel of the same name is not the cafe meant
            if m.get('kind') != 'coworking' \
                    and pl.get('primaryType') in NOT_A_CAFE:
                continue
            if same_place_name(m['place'], row['name']) \
                    or same_place_name(m['place'], _stem(row['name'])):
                alike.append((pl, row))
        if not alike:
            return out
        # The ones whose name is the name written, when there are any:
        # "Timberyard" is "Timberyard", open or closed, before it is
        # "Timberyard Seven Dials".
        exact = [x for x in alike
                 if same_telling_words(m['place'], x[1]['name'])
                 or same_telling_words(m['place'], _stem(x[1]['name']))]
        pool = exact or alike
        pick = [x for x in pool
                if x[0].get('businessStatus') in (None, 'OPERATIONAL')]
        if not pick:
            pl, row = pool[0]
            out.update(status='closed', google_place_id=row['id'],
                       google_name=row['name'])
            return out
        # Several alike and no branch named by the sites (a brand with
        # several places): no one of them is the place meant.
        if len(pick) > 1 and not area:
            out.update(status='several', google_name=pick[0][1]['name'])
            return out
        pl, row = pick[0]
        out.update(status='matched', google_place_id=row['id'],
                   google_name=row['name'], row=row)
        return out


def run(req, supabase_url, sb_headers, places_key, log=print):
    ev = Evidence(req, supabase_url, sb_headers, places_key, log=log)
    if not ev.read_plan():
        # the free matching costs nothing and still runs
        try:
            ev.rpc('mentions_match_local', {})
        except Exception:  # noqa: BLE001
            pass
        return ev
    ev.work_search()
    ev.check_mentions()
    log(f'Evidence: {ev.calls_made} calls made.')
    return ev
