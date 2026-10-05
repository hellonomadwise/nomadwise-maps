-- ============================================================
-- Migration 137: Candidates, with the search numbers and the reason.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026: "I want to know the reason why it is a
-- candidate ... whether Ahrefs says it has high traffic demand ...
-- list the cafes and coworking spaces with the highest probability
-- of bringing us more traffic, and generating us revenue."
--
-- Until now the list was ordered by what Google's reviews say about
-- working there. This adds what people search for:
--
--   candidate_search  monthly Google searches for a candidate's name
--                     (Ahrefs, worldwide), with how far the number
--                     can be trusted:
--                       sure     the name, or the name with its city
--                       city     only the name with the city counts
--                                (the bare name is a chain or a word)
--                       unsure   only the bare name has searches, and
--                                it may mean something else
--                       general  the name is too common to measure
--                       none     no searches found
--   region_search     monthly searches for "coworking <city>" and for
--                     cafes to work from there, and how hard Ahrefs
--                     rates the city search (0 easy, 100 hard)
--
-- and admin_candidates() now returns, for every card, the searches,
-- whether its city is a gap (people search for coworking there and we
-- list fewer than 8 coworking spaces), and a place in the list worked
-- out from all of it:
--
--   place = 10 x name points      (0 to 6: 10+, 30+, 100+, 200+, 500+,
--                                  1,000+ searches a month; 5 x
--                                  instead of 10 x when "unsure";
--                                  none when Google calls the place a
--                                  hotel, a hostel, a library and the
--                                  like, because those searches are
--                                  not for a place to work)
--         +  6 x gap points       (coworking spaces only: 5 when the
--                                  city has 1,000+ coworking searches
--                                  a month and we list fewer than 8
--                                  coworking spaces, 3 from 300)
--         +  8 for a coworking space (the kind that can become a
--                                  customer)
--         +  the review score of migration 129, unchanged.
--
-- The list can also be asked for by searches alone (p_sort =
-- 'searches'). The numbers are a snapshot: a place found after the
-- lookup has none until the next one, and stands in the list on its
-- reviews and its city. Later lookups are loaded with
-- set_candidate_search() and set_region_search(), which add to what
-- is there.
--
-- Nothing here writes to a candidate, a space or the website.
-- ============================================================

create table if not exists public.candidate_search (
  google_place_id text primary key,
  searches        integer not null default 0 check (searches >= 0),
  confidence      text not null
                  check (confidence in ('sure', 'city', 'unsure', 'general', 'none')),
  phrase          text check (char_length(phrase) <= 200),
  measured_on     date not null default current_date,
  updated_at      timestamptz not null default now()
);

create table if not exists public.region_search (
  region      text primary key,   -- the city page's name, lower case
  name        text not null,
  coworking   integer not null default 0 check (coworking >= 0),
  cafes       integer not null default 0 check (cafes >= 0),
  difficulty  integer check (difficulty between 0 and 100),
  measured_on date not null default current_date,
  updated_at  timestamptz not null default now()
);

alter table public.candidate_search enable row level security;
alter table public.region_search enable row level security;
drop policy if exists "candidate_search admin" on public.candidate_search;
create policy "candidate_search admin" on public.candidate_search
  for select using (public.is_admin());
drop policy if exists "region_search admin" on public.region_search;
create policy "region_search admin" on public.region_search
  for select using (public.is_admin());

-- Load a lookup: [{"place": "<google place id>", "searches": 870,
-- "confidence": "sure", "phrase": "the cluster"}]. Adds to what is
-- there; a place sent again is replaced. Returns how many were kept.
create or replace function public.set_candidate_search(p jsonb, p_on date default current_date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    return 0;
  end if;
  insert into public.candidate_search
    (google_place_id, searches, confidence, phrase, measured_on, updated_at)
  select distinct on (x.place)
         x.place, x.searches, x.confidence, x.phrase, coalesce(p_on, current_date), now()
    from (select btrim(e ->> 'place') as place,
                 case when (e ->> 'searches') ~ '^[0-9]{1,9}(\.[0-9]{1,6})?$'
                      then round((e ->> 'searches')::numeric)::integer
                      else 0 end as searches,
                 lower(btrim(coalesce(e ->> 'confidence', ''))) as confidence,
                 nullif(left(btrim(coalesce(e ->> 'phrase', '')), 200), '') as phrase
            from jsonb_array_elements(p) e
           where jsonb_typeof(e) = 'object') x
   where coalesce(x.place, '') <> ''
     and x.confidence in ('sure', 'city', 'unsure', 'general', 'none')
   order by x.place, x.searches desc
  on conflict (google_place_id) do update
    set searches = excluded.searches,
        confidence = excluded.confidence,
        phrase = excluded.phrase,
        measured_on = excluded.measured_on,
        updated_at = excluded.updated_at;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_candidate_search(jsonb, date) from public, anon, authenticated;
grant execute on function public.set_candidate_search(jsonb, date) to service_role;

-- Load the city searches: [{"region": "Lisbon", "coworking": 850,
-- "cafes": 80, "difficulty": 0}]. Same rules.
create or replace function public.set_region_search(p jsonb, p_on date default current_date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    return 0;
  end if;
  insert into public.region_search
    (region, name, coworking, cafes, difficulty, measured_on, updated_at)
  select distinct on (lower(x.name))
         lower(x.name), x.name, x.coworking, x.cafes, x.difficulty,
         coalesce(p_on, current_date), now()
    from (select btrim(coalesce(e ->> 'region', '')) as name,
                 case when (e ->> 'coworking') ~ '^[0-9]{1,9}(\.[0-9]{1,6})?$'
                      then round((e ->> 'coworking')::numeric)::integer
                      else 0 end as coworking,
                 case when (e ->> 'cafes') ~ '^[0-9]{1,9}(\.[0-9]{1,6})?$'
                      then round((e ->> 'cafes')::numeric)::integer
                      else 0 end as cafes,
                 case when (e ->> 'difficulty') ~ '^[0-9]{1,3}$'
                       and (e ->> 'difficulty')::integer <= 100
                      then (e ->> 'difficulty')::integer end as difficulty
            from jsonb_array_elements(p) e
           where jsonb_typeof(e) = 'object') x
   where x.name <> ''
   order by lower(x.name), x.coworking desc
  on conflict (region) do update
    set name = excluded.name,
        coworking = excluded.coworking,
        cafes = excluded.cafes,
        difficulty = excluded.difficulty,
        measured_on = excluded.measured_on,
        updated_at = excluded.updated_at;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_region_search(jsonb, date) from public, anon, authenticated;
grant execute on function public.set_region_search(jsonb, date) to service_role;

-- The list. The same places as migration 129 (nothing joins or
-- leaves the list), with the search numbers on each row and a new
-- order. The three-argument version goes, so there is one function
-- by this name; an app still sending three arguments gets this one
-- with the new order.
drop function if exists public.admin_candidates(text, integer, integer);

create or replace function public.admin_candidates(
  p_area   text default null,
  p_limit  integer default 60,
  p_offset integer default 0,
  p_sort   text default 'best')
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  out    jsonb;
  v_sort text := case when lower(btrim(coalesce(p_sort, ''))) = 'searches'
                      then 'searches' else 'best' end;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;

  with open_places as (
    select d.google_place_id, d.name, d.lat, d.lng, d.primary_type,
           d.rating, d.user_rating_count, d.signals_checked_at,
           d.fetched_at,
           coalesce(d.signal_wifi, 0)     as wifi,
           coalesce(d.signal_power, 0)    as power,
           coalesce(d.signal_laptop, 0)   as laptop,
           coalesce(d.signal_negative, 0) as negative,
           coalesce(d.signal_food, 0)     as food,
           (coalesce(d.primary_type, '') = 'coworking_space'
            or d.name ~* 'cowork|co-work|co work|workspace|work ?space|work ?hub|wework')
             as coworking
      from public.discovered_places d
     where not exists (select 1 from public.venues v
                        where v.google_place_id = d.google_place_id)
       and not exists (select 1 from public.candidate_decisions c
                        where c.google_place_id = d.google_place_id)
       -- petrol stations and convenience chains, as on the map
       and d.name !~* 'circle\s*k\M'
       and coalesce(d.primary_type, '') not in ('gas_station', 'convenience_store')
  ),
  worthy as (
    select o.*,
           3 * least(o.laptop, 5) + 2 * least(o.power, 5) + 2 * least(o.wifi, 5)
           + case when o.coworking then 4 else 0 end
           + case when o.rating >= 4.6 then 2
                  when o.rating >= 4.3 then 1
                  when o.rating <  3.8 then -2
                  else 0 end
           + case when o.user_rating_count >= 300 then 2
                  when o.user_rating_count >= 80  then 1
                  when o.user_rating_count <  10  then -1
                  else 0 end as score
      from open_places o
     where o.negative = 0
       and (o.wifi > 0 or o.power > 0 or o.laptop > 0 or o.coworking)
  ),
  -- The city page each one belongs to: the nearest Region within
  -- 30 km (the rule of candidate_region, written as one join here so
  -- a long list stays quick).
  nearest as (
    select distinct on (w.google_place_id)
           w.google_place_id,
           r.id   as region_id,
           r.name as region_name,
           nullif(trim(r.country), '') as region_country
      from worthy w
      join public.webflow_regions r
        on r.lat is not null and r.lng is not null
       and r.lat between w.lat - 0.3 and w.lat + 0.3
       and r.lng between w.lng - 1.0 and w.lng + 1.0
       and 6371 * 2 * asin(sqrt(least(1,
             power(sin(radians(r.lat - w.lat) / 2), 2)
             + cos(radians(w.lat)) * cos(radians(r.lat))
             * power(sin(radians(r.lng - w.lng) / 2), 2)))) <= 30
     order by w.google_place_id,
              power(r.lat - w.lat, 2)
              + power((r.lng - w.lng) * cos(radians(w.lat)), 2)
  ),
  located as (
    select w.*, n.region_id, n.region_name, n.region_country,
           coalesce(n.region_name, s.city, 'No city page nearby') as area
      from worthy w
      left join nearest n on n.google_place_id = w.google_place_id
      -- no city page nearby: name the city whose sweep found it
      left join lateral (
        select cs.city
          from public.city_sweeps cs
         where n.region_id is null
           and cs.center_lat is not null and cs.center_lng is not null
           and cs.center_lat between w.lat - 0.3 and w.lat + 0.3
           and cs.center_lng between w.lng - 1.0 and w.lng + 1.0
         order by power(cs.center_lat - w.lat, 2)
                + power((cs.center_lng - w.lng) * cos(radians(w.lat)), 2)
         limit 1) s on true
  ),
  -- What each city page lists today, from the nightly read of the
  -- pages (the page's own Region label), live pages only.
  listed as (
    select lower(btrim(f.facts ->> 'region')) as region,
           count(*) filter (where v.type = 'coworking') as coworking,
           count(*) filter (where v.type = 'cafe')      as cafes
      from public.venue_page_facts f
      join public.venues v on v.id = f.venue_id
     where btrim(coalesce(f.facts ->> 'region', '')) <> ''
       and v.website_status = 'released'
     group by 1
  ),
  scored as (
    select l.*,
           cs.searches     as searches,
           cs.confidence   as search_confidence,
           cs.phrase       as search_phrase,
           (cs.google_place_id is not null) as looked_up,
           rs.coworking    as city_searches,
           coalesce(li.coworking, 0)::integer as city_listed,
           -- Google says it is somewhere people stay or visit: its
           -- name is searched for that, not for a place to work.
           (coalesce(l.primary_type, '') in (
              'hotel', 'hostel', 'lodging', 'guest_house', 'bed_and_breakfast',
              'motel', 'inn', 'resort_hotel', 'extended_stay_hotel', 'library',
              'museum', 'university', 'school', 'educational_institution',
              'gym', 'fitness_center', 'shopping_mall', 'night_club'))
             as other_type
      from located l
      left join public.candidate_search cs on cs.google_place_id = l.google_place_id
      left join public.region_search rs on rs.region = lower(btrim(l.area))
      left join listed li on li.region = lower(btrim(l.area))
  ),
  pointed as (
    select s.*,
           case when not s.looked_up
                  or s.search_confidence in ('general', 'none')
                  or s.other_type then 0
                else case when s.searches >= 1000 then 6
                          when s.searches >= 500  then 5
                          when s.searches >= 200  then 4
                          when s.searches >= 100  then 3
                          when s.searches >= 30   then 2
                          when s.searches >= 10   then 1
                          else 0 end
           end as name_points,
           case when s.coworking and s.city_searches >= 300 and s.city_listed < 8
                then case when s.city_searches >= 1000 then 5 else 3 end
                else 0 end as gap_points,
           -- what "most searched" counts: a number that means the place
           case when s.looked_up and s.search_confidence in ('sure', 'city', 'unsure')
                then s.searches end as counted
      from scored s
  ),
  placed as (
    select p.*,
           -- a name that may mean something else counts half
           (case when p.search_confidence = 'unsure' then 5 else 10 end)
             * p.name_points
           + 6 * p.gap_points
           + case when p.coworking then 8 else 0 end
           + p.score as priority
      from pointed p
  ),
  page as (
    select q.*
      from (select p.*,
                   row_number() over (
                     order by case when v_sort = 'searches' then p.counted end desc nulls last,
                              p.priority desc,
                              p.counted desc nulls last,
                              p.user_rating_count desc nulls last,
                              p.name,
                              p.google_place_id) as rn
              from placed p
             where p_area is null or p.area = p_area) q
     order by q.rn
     limit greatest(1, least(coalesce(p_limit, 60), 200))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select jsonb_build_object(
    'total', (select count(*) from placed),
    'shown_total', (select count(*) from placed p
                     where p_area is null or p.area = p_area),
    'sort', v_sort,
    'areas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'area', a.area, 'n', a.n, 'has_page', a.has_page,
               'coworking_searches', a.coworking_searches,
               'cafe_searches', a.cafe_searches,
               'difficulty', a.difficulty,
               'coworking_listed', a.coworking_listed,
               'cafes_listed', a.cafes_listed)
               order by a.n desc, a.area)
        from (select p.area, count(*) as n,
                     bool_or(p.region_id is not null) as has_page,
                     max(rs.coworking)  as coworking_searches,
                     max(rs.cafes)      as cafe_searches,
                     max(rs.difficulty) as difficulty,
                     -- a city page with nothing live on it lists 0;
                     -- a place with no city page says nothing
                     case when bool_or(p.region_id is not null)
                          then coalesce(max(li.coworking), 0) end as coworking_listed,
                     case when bool_or(p.region_id is not null)
                          then coalesce(max(li.cafes), 0) end as cafes_listed
                from placed p
                left join public.region_search rs on rs.region = lower(btrim(p.area))
                left join listed li on li.region = lower(btrim(p.area))
               group by p.area) a), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'google_place_id', g.google_place_id,
               'name', g.name,
               'lat', g.lat,
               'lng', g.lng,
               'primary_type', g.primary_type,
               'coworking', g.coworking,
               'rating', g.rating,
               'user_rating_count', g.user_rating_count,
               'wifi', g.wifi,
               'power', g.power,
               'laptop', g.laptop,
               'food', g.food,
               'checked', g.signals_checked_at is not null,
               'score', g.score,
               'area', g.area,
               'region_id', g.region_id,
               'region_name', g.region_name,
               'region_country', g.region_country,
               'searches', case when g.looked_up then g.searches end,
               'search_confidence', g.search_confidence,
               'search_phrase', g.search_phrase,
               'city_searches', g.city_searches,
               'city_listed', g.city_listed,
               'other_type', g.other_type,
               'name_points', g.name_points,
               'gap_points', g.gap_points,
               'priority', g.priority)
               order by g.rn)
        from page g), '[]'::jsonb),
    -- found but not read yet: the nightly scan gets to 250 a night
    'waiting_scan', (select count(*) from open_places o
                      where o.signals_checked_at is null and not o.coworking),
    'dismissed', (select count(*) from public.candidate_decisions c
                   where c.decision = 'dismissed'),
    -- the day most of the search numbers are from, and how many
    -- places on the list were found after a lookup and have none
    'search_measured', (select mode() within group (order by cs.measured_on)
                          from public.candidate_search cs),
    'without_search', (select count(*) from placed p where not p.looked_up)
  ) into out;

  return out;
end $$;
revoke all on function public.admin_candidates(text, integer, integer, text)
  from public, anon;
grant execute on function public.admin_candidates(text, integer, integer, text)
  to authenticated;

-- The numbers of 5 Oct 2026 (Ahrefs, worldwide): 82 city pages and
-- the 477 candidates on the list that day.
select public.set_region_search($demand$[{"region":"London","coworking":3400,"cafes":390,"difficulty":7},{"region":"Bali","coworking":900,"cafes":0,"difficulty":2},{"region":"Bangkok","coworking":800,"cafes":40,"difficulty":46},{"region":"Chiang Mai","coworking":350,"cafes":10,"difficulty":null},{"region":"Koh Phangan","coworking":110,"cafes":0,"difficulty":null},{"region":"Lisbon","coworking":850,"cafes":80,"difficulty":0},{"region":"Lombok","coworking":70,"cafes":0,"difficulty":null},{"region":"Vienna","coworking":350,"cafes":50,"difficulty":2},{"region":"Barcelona","coworking":3300,"cafes":110,"difficulty":74},{"region":"Hamburg","coworking":1400,"cafes":0,"difficulty":2},{"region":"Budapest","coworking":500,"cafes":30,"difficulty":8},{"region":"Ho Chi Minh City","coworking":190,"cafes":0,"difficulty":null},{"region":"Da Nang","coworking":300,"cafes":0,"difficulty":null},{"region":"Munich","coworking":1800,"cafes":40,"difficulty":1},{"region":"Dubai","coworking":1500,"cafes":80,"difficulty":4},{"region":"Siargao","coworking":70,"cafes":0,"difficulty":null},{"region":"Madeira","coworking":70,"cafes":0,"difficulty":null},{"region":"Berlin","coworking":3200,"cafes":200,"difficulty":41},{"region":"Tallinn","coworking":500,"cafes":0,"difficulty":34},{"region":"Koh Lanta","coworking":20,"cafes":0,"difficulty":null},{"region":"Koh Tao","coworking":30,"cafes":0,"difficulty":null},{"region":"Ericeira","coworking":120,"cafes":0,"difficulty":null},{"region":"Bratislava","coworking":410,"cafes":0,"difficulty":null},{"region":"Copenhagen","coworking":550,"cafes":20,"difficulty":0},{"region":"Kuala Lumpur","coworking":750,"cafes":60,"difficulty":47},{"region":"Prague","coworking":500,"cafes":0,"difficulty":79},{"region":"Santiago","coworking":400,"cafes":0,"difficulty":0},{"region":"Colombo","coworking":550,"cafes":10,"difficulty":null},{"region":"Oldenburg","coworking":350,"cafes":0,"difficulty":0},{"region":"Split","coworking":210,"cafes":0,"difficulty":null},{"region":"Athens","coworking":400,"cafes":20,"difficulty":21},{"region":"Valencia","coworking":2650,"cafes":10,"difficulty":0},{"region":"Sao Vicente","coworking":300,"cafes":0,"difficulty":null},{"region":"Ulm","coworking":190,"cafes":0,"difficulty":null},{"region":"Quito","coworking":230,"cafes":0,"difficulty":10},{"region":"East Java","coworking":0,"cafes":0,"difficulty":null},{"region":"Koh Samui","coworking":90,"cafes":0,"difficulty":null},{"region":"Gili Islands","coworking":0,"cafes":0,"difficulty":null},{"region":"Sal","coworking":300,"cafes":0,"difficulty":null},{"region":"Florence","coworking":120,"cafes":0,"difficulty":0},{"region":"Paphos","coworking":30,"cafes":0,"difficulty":null},{"region":"Manchester","coworking":1800,"cafes":110,"difficulty":44},{"region":"Seoul","coworking":70,"cafes":0,"difficulty":null},{"region":"Muenster","coworking":0,"cafes":0,"difficulty":null},{"region":"Central Singapore","coworking":30,"cafes":0,"difficulty":null},{"region":"Boa Vista","coworking":300,"cafes":0,"difficulty":null},{"region":"Arusha","coworking":0,"cafes":0,"difficulty":null},{"region":"Kandy","coworking":0,"cafes":0,"difficulty":null},{"region":"Peniche","coworking":20,"cafes":0,"difficulty":null},{"region":"El Nido","coworking":40,"cafes":0,"difficulty":null},{"region":"Wiggensbach","coworking":0,"cafes":0,"difficulty":null},{"region":"Lancaster","coworking":10,"cafes":0,"difficulty":null},{"region":"Kotor","coworking":0,"cafes":0,"difficulty":null},{"region":"Asunci\u00f3n","coworking":150,"cafes":0,"difficulty":null},{"region":"Brighton","coworking":1100,"cafes":40,"difficulty":26},{"region":"Bengaluru","coworking":140,"cafes":0,"difficulty":null},{"region":"Duluth, MN","coworking":0,"cafes":0,"difficulty":null},{"region":"Hannover","coworking":600,"cafes":0,"difficulty":0},{"region":"New York City","coworking":1250,"cafes":0,"difficulty":37},{"region":"Amsterdam","coworking":1800,"cafes":180,"difficulty":6},{"region":"Tangalle","coworking":0,"cafes":0,"difficulty":null},{"region":"Hurghada","coworking":30,"cafes":0,"difficulty":null},{"region":"Nusa Penida","coworking":0,"cafes":0,"difficulty":null},{"region":"Cairns","coworking":50,"cafes":0,"difficulty":3},{"region":"Hochtaunuskreis","coworking":0,"cafes":0,"difficulty":null},{"region":"Plymouth","coworking":40,"cafes":0,"difficulty":0},{"region":"Penang","coworking":150,"cafes":0,"difficulty":null},{"region":"Paris","coworking":4700,"cafes":280,"difficulty":3},{"region":"Pai","coworking":0,"cafes":0,"difficulty":null},{"region":"Nijmegen","coworking":200,"cafes":0,"difficulty":0},{"region":"Melbourne","coworking":1800,"cafes":90,"difficulty":4},{"region":"Hanoi","coworking":270,"cafes":0,"difficulty":57},{"region":"Cape Town","coworking":300,"cafes":10,"difficulty":1},{"region":"Taipei","coworking":300,"cafes":0,"difficulty":0},{"region":"Madrid","coworking":3050,"cafes":100,"difficulty":2},{"region":"Surat Thani","coworking":0,"cafes":0,"difficulty":null},{"region":"Vancouver","coworking":800,"cafes":50,"difficulty":28},{"region":"Mallorca","coworking":350,"cafes":0,"difficulty":null},{"region":"Rhodes","coworking":60,"cafes":0,"difficulty":null},{"region":"Crete","coworking":0,"cafes":0,"difficulty":null},{"region":"Istanbul","coworking":300,"cafes":0,"difficulty":0},{"region":"Vechta","coworking":0,"cafes":0,"difficulty":null}]$demand$::jsonb, date '2026-10-05');

select public.set_candidate_search($demand$[{"place":"ChIJ37zJw0VJYA0RM-J-W3UeCWs","searches":90,"confidence":"unsure","phrase":"cowork up ruzafa"},{"place":"ChIJuyTjZopD1moRXJ3cMeSk0Qo","searches":100,"confidence":"city","phrase":"workspaces melbourne"},{"place":"ChIJA2hspGZD1moRIuVMLN4KnAA","searches":100,"confidence":"city","phrase":"workspaces melbourne"},{"place":"ChIJoTtMOpA1GQ0R63Ie2NdXcUA","searches":0,"confidence":"none","phrase":"10cowork"},{"place":"ChIJjXrn_3Jd1moRAXWkXPzEV5A","searches":0,"confidence":"none","phrase":"1smart space"},{"place":"ChIJJ6e94bWsU0YR8Bzxlh5PK-g","searches":0,"confidence":"general","phrase":"24labs"},{"place":"ChIJwX10Nl01GQ0RJQc5PaRuYk0","searches":0,"confidence":"none","phrase":"27 spaces"},{"place":"ChIJtee3pH872jAR90qc25Kpy-w","searches":0,"confidence":"none","phrase":"4seas nimman coliving coworking space"},{"place":"ChIJH_2izRlTUkYRFwcJ3OYq3iA","searches":0,"confidence":"general","phrase":"5tested"},{"place":"ChIJha7uhJ9H0i0R2aYDY-3wRb0","searches":0,"confidence":"none","phrase":"7am bakers bumbak dauh kerobokan"},{"place":"ChIJWcgLlz81GQ0RBY-8AuV52EI","searches":0,"confidence":"general","phrase":"a casa"},{"place":"ChIJG15z3h0zGQ0RvXeeaGTThIc","searches":0,"confidence":"none","phrase":"a dama rosa co working event space"},{"place":"ChIJi5ZrNyRD1moRWBX0BgmzkJI","searches":0,"confidence":"none","phrase":"ab unity partners"},{"place":"ChIJCQnHWaBD1moRnAJ0xPZLWe4","searches":0,"confidence":"none","phrase":"acceler8 co working space"},{"place":"ChIJ79LF_XkzGQ0R1suPzDgueB8","searches":0,"confidence":"none","phrase":"adrinalina beauty coworking"},{"place":"ChIJV-GK9YVmmUcRqhMa5SrLBmo","searches":150,"confidence":"city","phrase":"alba ulm"},{"place":"ChIJbcLO2JH1nEcRCDjIz5JZbnY","searches":0,"confidence":"none","phrase":"allgau coworking gmbh"},{"place":"ChIJgd69OIz1nEcRc52KlchONNA","searches":0,"confidence":"none","phrase":"allgau coworking gmbh"},{"place":"ChIJzzZjeCpjnEcRRMExxHt5oYw","searches":0,"confidence":"none","phrase":"allgau coworking gmbh"},{"place":"ChIJexz4rMY72jARS9lAT2HolCs","searches":10,"confidence":"unsure","phrase":"alt pingriver"},{"place":"ChIJq6qqpXyrU0YRCMyCwCzhNaw","searches":0,"confidence":"none","phrase":"amagerstrand united"},{"place":"ChIJe2c_HE4zGQ0RcMPRWBiMsrk","searches":0,"confidence":"general","phrase":"amor perfeito"},{"place":"ChIJrd_vckMbdkgRSZLg_mdZjho","searches":270,"confidence":"sure","phrase":"anomalous space"},{"place":"ChIJPaJMbuo50i0RHNlPmL7WJuM","searches":0,"confidence":"none","phrase":"another fcking cafe"},{"place":"ChIJ1SwFXRYX0i0RL2nuf2REbUg","searches":0,"confidence":"none","phrase":"anufa office"},{"place":"ChIJ0f_fW2I72jARK4JUWxWZTVI","searches":0,"confidence":"none","phrase":"anyday coffee coworking space"},{"place":"ChIJycOcbkdd1moRVXC7QztBHHU","searches":200,"confidence":"sure","phrase":"apollo melbourne"},{"place":"ChIJEYegXwpTUkYRhWpEjds9Quk","searches":0,"confidence":"none","phrase":"arbejdsfaellesskabet tranen"},{"place":"ChIJ01RpbAVjmUcRq7v_MCYYiDM","searches":400,"confidence":"unsure","phrase":"area 91"},{"place":"ChIJ-yyKb6OhU0YRrJu8p2sRWVg","searches":0,"confidence":"none","phrase":"arena triangeln coworking"},{"place":"ChIJEzGvUdhvn48R1NEdSFwlUCA","searches":0,"confidence":"none","phrase":"ares workspace"},{"place":"ChIJpXcXPl462jAR3vTBJWCqkjY","searches":250,"confidence":"unsure","phrase":"atelier 36"},{"place":"ChIJd_eFRiaf4jART-XVfTJTcqA","searches":30,"confidence":"unsure","phrase":"atlas workspace asoke"},{"place":"ChIJy0EPQzdd1moRRbFM1pWLJow","searches":0,"confidence":"none","phrase":"austramax house"},{"place":"ChIJMUIsYAozGQ0R2w_rEWu43Mk","searches":360,"confidence":"sure","phrase":"avila spaces"},{"place":"ChIJPx9KIE5F1moRcAqowq62OeE","searches":0,"confidence":"none","phrase":"b east studios spaces and storage"},{"place":"ChIJD2rLBSjNHg0RZQlgSmnqwUM","searches":0,"confidence":"none","phrase":"baldaya palace coworking space"},{"place":"ChIJKSDAlGlzIg0RqlHtcmH5_KE","searches":0,"confidence":"general","phrase":"base"},{"place":"ChIJ2bx9xOt1nkcR0p1qsYhdNww","searches":110,"confidence":"sure","phrase":"base coworking"},{"place":"ChIJU3W3ZBFTUkYRR1sx91IE5FM","searches":700,"confidence":"city","phrase":"bastard cafe copenhagen"},{"place":"ChIJVVXlEVrvGRMRdk0LqK-YwvA","searches":20,"confidence":"unsure","phrase":"beet community"},{"place":"ChIJQZ-4q5TlGRMRbsIdl_-d9Do","searches":0,"confidence":"general","phrase":"beetcommunity"},{"place":"ChIJY4wRTB1TUkYRtRFg2uIkA-M","searches":0,"confidence":"none","phrase":"bernies coworking space"},{"place":"ChIJFZFH8aEzGQ0R-Xuk90YzDsM","searches":0,"confidence":"general","phrase":"best office"},{"place":"ChIJ7fLRQ2pTUkYRpUBTuVNrx8M","searches":0,"confidence":"none","phrase":"beta boulders vanlose"},{"place":"ChIJ0zF7994bdkgRKsBgsrtzDqk","searches":260,"confidence":"sure","phrase":"better space"},{"place":"ChIJS_h_LAdTUkYRgXKsFOP11fg","searches":10,"confidence":"city","phrase":"bevars copenhagen"},{"place":"ChIJw2mfIIue4jARMOALrQlGEvI","searches":100,"confidence":"unsure","phrase":"big co working space"},{"place":"ChIJj_lWHblD1moRXyUPnqMtHUQ","searches":0,"confidence":"none","phrase":"bird coworking"},{"place":"ChIJG3_r8HMbdkgR9HidOPXWY6k","searches":1300,"confidence":"city","phrase":"blank street coffee london"},{"place":"ChIJJYeD6ZZnmUcRpRkh3JIXqdk","searches":10,"confidence":"city","phrase":"cafe bar ulm"},{"place":"ChIJpWCk_oNmmUcRVOdvz2IHG5o","searches":0,"confidence":"none","phrase":"cafe bar kafenio"},{"place":"ChIJZyNWTMw4u0cRVc1fgXoa9sQ","searches":0,"confidence":"general","phrase":"cafe hurricane"},{"place":"ChIJyWfFQjBnmUcREgU6T7WPMDk","searches":20,"confidence":"unsure","phrase":"cafe im hugendubel"},{"place":"ChIJq_igeABTUkYRBeiVQnmoErA","searches":0,"confidence":"general","phrase":"capella house"},{"place":"ChIJs8WOodNC1moRTTKDlKMxjkg","searches":30,"confidence":"unsure","phrase":"carlton connect initiative"},{"place":"ChIJh1BA958zGQ0RCs0RfxItaC4","searches":0,"confidence":"none","phrase":"casa casa cafe"},{"place":"ChIJXZh9xqpC1moRzArHU1cCceM","searches":10,"confidence":"sure","phrase":"central house south melbourne"},{"place":"ChIJowEzH-JD1moR2VSM1jKFJPk","searches":20,"confidence":"unsure","phrase":"central house toorak"},{"place":"ChIJqfC2grZC1moR6d9Yu2dg8EM","searches":0,"confidence":"general","phrase":"chantilly studio"},{"place":"ChIJ2WpwylY1GQ0R9ptNQyjDMSI","searches":20,"confidence":"unsure","phrase":"clube caffeine"},{"place":"ChIJCRlZWJA72jARl42OCRD8Dp8","searches":0,"confidence":"none","phrase":"cmu learning space"},{"place":"ChIJpdxlHr072jARAyQ6NYZ3T_o","searches":0,"confidence":"none","phrase":"cnxbackstage"},{"place":"ChIJIVgJWQA72jARFkyI5oPdBiw","searches":0,"confidence":"none","phrase":"co murata"},{"place":"ChIJ3emMQRxD1moRl5YNHrOuEvc","searches":0,"confidence":"general","phrase":"co studio"},{"place":"ChIJvRDzFgA72jAReSxAPV1Y2BM","searches":0,"confidence":"none","phrase":"co working space physics1"},{"place":"ChIJD1ehO7lD1moRxUAnnl3CShI","searches":0,"confidence":"general","phrase":"co bake space"},{"place":"ChIJj8zI6N8PIg0RMkFslhi3LTw","searches":0,"confidence":"none","phrase":"cobo cowork"},{"place":"ChIJy_p2bxdTUkYRPKPZZHLCDKA","searches":100,"confidence":"sure","phrase":"coffee collective bernikow"},{"place":"ChIJt9b4YmBD1moRqnxhUODkiSA","searches":0,"confidence":"none","phrase":"collective 100 flexible workspace cremorne"},{"place":"ChIJ5T_tgxg50i0RshnF8IXoHaI","searches":0,"confidence":"general","phrase":"conest"},{"place":"ChIJa-Ivp3szGQ0RnlXBPHGZxEE","searches":0,"confidence":"general","phrase":"connection cafe"},{"place":"ChIJj25MAs8EdkgRpatOJnQ-rRE","searches":20,"confidence":"unsure","phrase":"connections at trafalgar square"},{"place":"ChIJD1wvGwAzGQ0RvyoKhMxC-Xo","searches":0,"confidence":"none","phrase":"consultorios em lisboa"},{"place":"ChIJz8JKhHVF1moRRNNu4yGfHsA","searches":0,"confidence":"general","phrase":"coparadiso"},{"place":"ChIJN474c1RSUkYR6fofv4RtziY","searches":10,"confidence":"sure","phrase":"copenhagen bio science park"},{"place":"ChIJm0Xsxj9TUkYRkOPRCdyFwmo","searches":40,"confidence":"sure","phrase":"copenhagen fintech lab"},{"place":"ChIJ77qOqJxd1moRKjeZwyLaEwQ","searches":0,"confidence":"general","phrase":"corize"},{"place":"ChIJ4VBpdSxD1moRieBBDuAaVDs","searches":0,"confidence":"none","phrase":"corporatecubes co"},{"place":"ChIJ6_fuu5Vd1moRmCVC280HaQ4","searches":0,"confidence":"none","phrase":"corporatecubes co"},{"place":"ChIJp2mqwYld1moRaQ-oysCcTIQ","searches":0,"confidence":"none","phrase":"corporatecubes co"},{"place":"ChIJSzrIAJt3nEcRk1QD5v6Xgqk","searches":0,"confidence":"general","phrase":"costall"},{"place":"ChIJaQ1iBMoV0i0RdV1bW8_zKUA","searches":0,"confidence":"none","phrase":"covision innovation space"},{"place":"ChIJDeNWH-I1GQ0Rg8_GRj6V4xQ","searches":0,"confidence":"general","phrase":"cowork almada"},{"place":"ChIJ3w-M7jRPYA0RthLD_IbzPyE","searches":0,"confidence":"general","phrase":"cowork ruzafa"},{"place":"ChIJGaSYTtNYnEcRMJPiGRQWhKg","searches":0,"confidence":"none","phrase":"coworking am see"},{"place":"ChIJteAzhBwzGQ0RmuuVehHVCqA","searches":0,"confidence":"none","phrase":"coworking business networking lounge"},{"place":"ChIJwxGh7MA5u0cR8Dj6MoRjQHU","searches":0,"confidence":"none","phrase":"coworking cassel depo"},{"place":"ChIJwbDmIgJHu0cR0KBw8gvcjqs","searches":0,"confidence":"general","phrase":"coworking kassel"},{"place":"ChIJd2-2tZAzGQ0RtA-74qiWuSg","searches":0,"confidence":"none","phrase":"coworking new space"},{"place":"ChIJdzEnVd7pGRMRNFJMD0AHLZo","searches":0,"confidence":"none","phrase":"coworking palermo spazi di lavoro condiviso"},{"place":"ChIJm4BvZsUj0i0RtslWJB3wRdU","searches":0,"confidence":"none","phrase":"coworking space eatery in ubud"},{"place":"ChIJX8sOAD91nkcRuAEOenOj-Vc","searches":0,"confidence":"none","phrase":"coworking space munchen"},{"place":"ChIJo42KgONSUkYREEIJOP-coeE","searches":0,"confidence":"none","phrase":"coworking space studio cph"},{"place":"ChIJyzmFzrmlGA0RMGP_zQlA8sU","searches":0,"confidence":"general","phrase":"coworking spot"},{"place":"ChIJX3uJXyNlmUcRRkJvnsYHLhc","searches":0,"confidence":"none","phrase":"coworking stadtregal ulm"},{"place":"ChIJ90E_8KJPYA0R34t8oFKEg2Y","searches":0,"confidence":"none","phrase":"coworking tambori"},{"place":"ChIJt8OjuGxmmUcRskFvOdeNF20","searches":0,"confidence":"general","phrase":"coworking ulm"},{"place":"ChIJvY0zdIRp1moR4fMvL-Js8uU","searches":0,"confidence":"none","phrase":"cray cray co"},{"place":"ChIJDfArCtRp1moRFkLfgcktovo","searches":0,"confidence":"none","phrase":"creativecubes co"},{"place":"ChIJwdBmBz5D1moR1tzselktEIw","searches":0,"confidence":"none","phrase":"creativecubes co"},{"place":"ChIJybIB6w5D1moRHrxt5s4Qd84","searches":0,"confidence":"none","phrase":"creativecubes co"},{"place":"ChIJQ8ZRJypD1moR_4AvOJ3Esl8","searches":0,"confidence":"none","phrase":"creativecubes co"},{"place":"ChIJjQLwoTFC1moR6elVKH1Ryw4","searches":0,"confidence":"none","phrase":"creativecubes co"},{"place":"ChIJIxlEK4xC1moRslH_-9RMzx4","searches":0,"confidence":"none","phrase":"creativecubes co"},{"place":"ChIJS5lO46Vn1moRSPXK15kMAWM","searches":0,"confidence":"none","phrase":"creativecubes co"},{"place":"ChIJhVmcRB4zGQ0RlNFEMJLv38Q","searches":0,"confidence":"none","phrase":"creativerez"},{"place":"ChIJpVzemNRD1moRL-jXbaHttpg","searches":100,"confidence":"unsure","phrase":"cremorne digital hub"},{"place":"ChIJ68pMUeZD1moR4Dxk0El6r0M","searches":0,"confidence":"none","phrase":"curago coworking"},{"place":"ChIJsSNMlUJD1moRDKYSxhI0g_Y","searches":70,"confidence":"sure","phrase":"czar workspace"},{"place":"ChIJE8MHV3lVUkYRGkShb_z_Wpw","searches":30,"confidence":"unsure","phrase":"dark atelier"},{"place":"ChIJHb52J2QX0i0R11oqgb2XjM8","searches":0,"confidence":"none","phrase":"dayu sri wedari"},{"place":"ChIJE7Tn3OSe4jARoCiL02GroTY","searches":0,"confidence":"none","phrase":"dcubic design space co ltd"},{"place":"ChIJ5wPsoHxRUkYR4iXPt_237Uc","searches":0,"confidence":"none","phrase":"design district cph"},{"place":"ChIJiS7qSrMDdkgR_YFY1vbX2RM","searches":0,"confidence":"general","phrase":"deskhive"},{"place":"ChIJWQIjsrRD1moRVhOwmoMswHQ","searches":0,"confidence":"none","phrase":"deskplex 5 star designer office spaces"},{"place":"ChIJFfKD5D9o1moRdAcRKFtM6jU","searches":0,"confidence":"none","phrase":"deskworx and deskworx seminars"},{"place":"ChIJQxwviHE72jARsmBN3eUicgo","searches":0,"confidence":"none","phrase":"desoft space"},{"place":"ChIJaaAF88czGQ0RUMQJzpMz8vA","searches":10,"confidence":"unsure","phrase":"do beco estefania"},{"place":"ChIJL1fFC4w1GQ0RGjX8rqEgpZo","searches":0,"confidence":"general","phrase":"dream office"},{"place":"ChIJ-dpbb5Y90i0RVr-MBd8rla4","searches":150,"confidence":"unsure","phrase":"eden lounge ubud"},{"place":"ChIJj0Wt1ZMzGQ0RfWutlgog9iY","searches":0,"confidence":"none","phrase":"edificio de escritorio moscavide 26"},{"place":"ChIJX4QAKNRD1moR5TUuZmIVv-Q","searches":0,"confidence":"none","phrase":"edinburgh village studio"},{"place":"ChIJKUBJQvp5nEcRMwmEtm7C5jk","searches":0,"confidence":"none","phrase":"einstein work businessplace coworking"},{"place":"ChIJN_PVIJmCiwYR7g2w5mhRoJ8","searches":0,"confidence":"none","phrase":"einstein work businessplace coworking dietmannsried"},{"place":"ChIJg4y1JCI_u0cR5WFjHToo17g","searches":0,"confidence":"general","phrase":"eisquartier"},{"place":"ChIJHSxi2H8zGQ0Rrk1eSoRL_TM","searches":10,"confidence":"city","phrase":"elevada lisbon"},{"place":"ChIJBxhOLbQzGQ0RJOrjjEq-Bls","searches":0,"confidence":"none","phrase":"eli co escritorios privados coworking lisboa"},{"place":"ChIJVW5GUwAzGQ0RrzKHKgAL5t0","searches":0,"confidence":"general","phrase":"elo house"},{"place":"ChIJoyhHNAYzGQ0RgPxPE45uUAM","searches":0,"confidence":"general","phrase":"emmim"},{"place":"ChIJMcX-2u4zGQ0RPr095qT_jog","searches":0,"confidence":"none","phrase":"emporium coworking"},{"place":"ChIJvVTwfbtp1moRyxxiE4uExn0","searches":20,"confidence":"unsure","phrase":"engine house balaclava"},{"place":"ChIJ4WMz0Dho1moRX9KoNXinxcI","searches":20,"confidence":"unsure","phrase":"engine house st kilda"},{"place":"ChIJ0_MwihdJYA0Rk885U_LLC9c","searches":0,"confidence":"none","phrase":"espacio bica ruzafa coworking"},{"place":"ChIJ8wdUKa-nGA0RKcbs_BnB0X4","searches":0,"confidence":"none","phrase":"espaco coworking alcobaca"},{"place":"ChIJ17PZzhQzGQ0RFwbSX907K-0","searches":0,"confidence":"none","phrase":"espaco equilibrio terapias"},{"place":"ChIJD6IoafHNHg0RC7Gk36SDcAw","searches":0,"confidence":"none","phrase":"espacos benfica"},{"place":"ChIJHUQTbB1TUkYRY8ZctdvWGlA","searches":0,"confidence":"none","phrase":"esrummet"},{"place":"ChIJyX754F4zGQ0RJVd81pi2EVY","searches":0,"confidence":"general","phrase":"eureka coworking"},{"place":"ChIJAQDAr2dn1moRxny62mCyQZU","searches":0,"confidence":"general","phrase":"evolving spaces"},{"place":"ChIJ0xBsq5JC1moR-H_gKZajQ0I","searches":0,"confidence":"none","phrase":"exchange workspaces richmond"},{"place":"ChIJOfGsRw6o2EcR2bzSEgqt9QQ","searches":30,"confidence":"unsure","phrase":"expressway by general people"},{"place":"ChIJeXv-Hd8zGQ0RBXp2t1hA4eU","searches":200,"confidence":"unsure","phrase":"fabrica moderna"},{"place":"ChIJy4rZCExYzpQR3iRkNvjuVxU","searches":0,"confidence":"general","phrase":"facts coworking"},{"place":"ChIJe63SN_RTUkYRdqosOevZdHY","searches":0,"confidence":"none","phrase":"faellesskabet"},{"place":"ChIJ_SUKQc4x2jARISNszFIjjn8","searches":0,"confidence":"none","phrase":"fellowship cafe co working"},{"place":"ChIJAQBQG5pTUkYRzmzyYvVlu7g","searches":0,"confidence":"general","phrase":"ferdinand"},{"place":"ChIJAygZTsAzGQ0R63HLw-Kaogc","searches":0,"confidence":"none","phrase":"ffeio telheiras"},{"place":"ChIJ6U79zP1TUkYRgpSAnGpi4sg","searches":0,"confidence":"general","phrase":"fishtank"},{"place":"ChIJ9VvPTAB5nEcR0yW0zM5d6Bo","searches":40,"confidence":"unsure","phrase":"fiume sommerbar"},{"place":"ChIJd0n5wTtd1moRurvKTArKftc","searches":20,"confidence":"sure","phrase":"flex south melbourne"},{"place":"ChIJSyC4y0xJUkYR8VsVNRclP94","searches":0,"confidence":"general","phrase":"flexum coworking"},{"place":"ChIJ_-EkGsSp2EcR0fYO_PUdc3o","searches":0,"confidence":"none","phrase":"flipper hackspace"},{"place":"ChIJF22xUGU1GQ0RuxkjkKDLYkA","searches":0,"confidence":"none","phrase":"fluiroffice"},{"place":"ChIJrXTcC6ANcm0RhXKowA6Kirc","searches":70,"confidence":"sure","phrase":"folks coliving valencia"},{"place":"ChIJx0ROvCFd1moRV7MhLjuJwn8","searches":0,"confidence":"none","phrase":"footscray coworking space"},{"place":"ChIJc0VyC43NHg0REK0nFNAjdVM","searches":0,"confidence":"none","phrase":"forja cowork studio"},{"place":"ChIJTZPjKgBD1moRsk2X-HSZZmw","searches":0,"confidence":"none","phrase":"forum workspace cremorne"},{"place":"ChIJ3ZsEikdp1moRhIcbb5erIy8","searches":10,"confidence":"unsure","phrase":"freedom suites"},{"place":"ChIJKzbHz0wbdkgRA6q3uqup9SE","searches":200,"confidence":"unsure","phrase":"frothee kings cross"},{"place":"ChIJ38knabpH0i0RXvdepV3-1OU","searches":0,"confidence":"general","phrase":"g88 coworking space"},{"place":"ChIJ3drY4FFPYA0R6jFt9584owg","searches":0,"confidence":"sure","phrase":"garage coworking club house valencia"},{"place":"ChIJVVVlWoRmmUcRpP8u4Ck7Cq8","searches":50,"confidence":"city","phrase":"garden bar ulm"},{"place":"ChIJWXRaz_kX0i0RUnaHkTE0WXI","searches":10,"confidence":"city","phrase":"gardener bali"},{"place":"ChIJ0_v2gHEx2jAR1qNBKa406eA","searches":0,"confidence":"none","phrase":"gardenzenment co working space and conference meeting venue"},{"place":"ChIJM4cpDTobdkgRx8LDQJ76Yu8","searches":9000,"confidence":"sure","phrase":"generator london"},{"place":"ChIJubMwcbR3nEcR5I2KtuXpAIU","searches":10,"confidence":"unsure","phrase":"geschaftsadresse mieten"},{"place":"ChIJ3Xz2m3-bfDURYXA7FggXUps","searches":0,"confidence":"none","phrase":"glow music studio"},{"place":"ChIJC_-nmXjh6KwRRPimSL5haXQ","searches":220,"confidence":"sure","phrase":"good company books"},{"place":"ChIJxy4X4jBd1moRT8z-a0KMOuE","searches":0,"confidence":"none","phrase":"gpt space co 530 collins street"},{"place":"ChIJY1KLxspC1moR3ga7Atypw3o","searches":0,"confidence":"sure","phrase":"gpt space co melbourne central"},{"place":"ChIJebrb9uBp1moRavvvN08CAJw","searches":0,"confidence":"none","phrase":"gracies space"},{"place":"ChIJZQSq23072jARs_w4WR4XeZg","searches":0,"confidence":"none","phrase":"greenhouse community space"},{"place":"ChIJcc20DIxp1moRLrHxChTrqzQ","searches":0,"confidence":"none","phrase":"hawk nest coworking"},{"place":"ChIJZ3o2-QkzGQ0R-Ij4jj55EmE","searches":0,"confidence":"none","phrase":"haws lisboa coworking"},{"place":"ChIJAQBAtMJSUkYRnTmraR3JSnc","searches":40,"confidence":"sure","phrase":"health tech hub copenhagen"},{"place":"ChIJjYF4qrwzGQ0R9kcBTDClZhs","searches":0,"confidence":"none","phrase":"heden workspaces"},{"place":"ChIJNdI73841GQ0RWO1zIAScdJ4","searches":0,"confidence":"none","phrase":"heden workspaces"},{"place":"ChIJVQpoqGsnHw0RCAgwNFp_6y4","searches":0,"confidence":"sure","phrase":"hokapia ericeira"},{"place":"ChIJ1bcLqElPYA0RSR6or2uauyo","searches":2800,"confidence":"sure","phrase":"hotel conqueridor"},{"place":"ChIJIxLlJgBTUkYRRqUDc5pEe2M","searches":0,"confidence":"none","phrase":"hovedkvarteret kontorfaellesskab"},{"place":"ChIJ-b9ovtUzGQ0RceSn9N_JTTE","searches":330,"confidence":"sure","phrase":"how about coffee"},{"place":"ChIJPa-tX9FD1moRn84DFreukd8","searches":150,"confidence":"unsure","phrase":"hub collins street"},{"place":"ChIJh_uJQU5d1moRWkYFEIn_jgs","searches":150,"confidence":"unsure","phrase":"hub southern cross"},{"place":"ChIJ4Zr_bfVD1moRt_8Q14GuYAw","searches":40,"confidence":"unsure","phrase":"hub st kilda road"},{"place":"ChIJa70Qnq8zGQ0R32XBnQKqbKg","searches":0,"confidence":"general","phrase":"hub55"},{"place":"ChIJlXVaJkwzGQ0Rykck0sBwx_8","searches":0,"confidence":"none","phrase":"hugos premium office and coworking space"},{"place":"ChIJIzb2YAdnmUcR_u5v4ULVrWs","searches":0,"confidence":"none","phrase":"hybridworx"},{"place":"ChIJb-Qo1HUzGQ0RvaR8Qrbac1A","searches":350,"confidence":"sure","phrase":"idea spaces"},{"place":"ChIJb5F6jYgxGQ0RK0uxAJ8u3WU","searches":350,"confidence":"sure","phrase":"idea spaces"},{"place":"ChIJjUqdIC4zGQ0RJFZYZZOXe3k","searches":350,"confidence":"sure","phrase":"idea spaces"},{"place":"ChIJU8unsDYzGQ0R44LricHKZy8","searches":100,"confidence":"sure","phrase":"impact hub lisbon"},{"place":"ChIJjd3L6SRo1moRbCNvm-vC35s","searches":150,"confidence":"unsure","phrase":"independent studios"},{"place":"ChIJmUqFBJNC1moRKBoo_6kUSwU","searches":230,"confidence":"sure","phrase":"inspire9"},{"place":"ChIJy8QwYKNUUkYR8yc-q38Lkf4","searches":200,"confidence":"city","phrase":"international house copenhagen"},{"place":"ChIJB5AU9ewY0i0R4c0H4YnduSM","searches":0,"confidence":"none","phrase":"jero alit"},{"place":"ChIJd4Kq809D1moReVLDjews3OI","searches":0,"confidence":"general","phrase":"jumpspace"},{"place":"ChIJG0GtyIZd1moR619xoNd7HEs","searches":80,"confidence":"city","phrase":"justco melbourne"},{"place":"ChIJF6n3GB2f4jARFmTczpvOVNk","searches":250,"confidence":"city","phrase":"justco bangkok"},{"place":"ChIJn3uv4eFD1moRcszR0qOrj5w","searches":0,"confidence":"sure","phrase":"justco emporium melbourne"},{"place":"ChIJ52vtL2hnmUcR30yyaMbK-WM","searches":10,"confidence":"unsure","phrase":"kaffee fred ulm"},{"place":"ChIJmeTy9DR5nEcRTKyLIW4yTPM","searches":0,"confidence":"none","phrase":"kara brew bar kempten"},{"place":"ChIJn4NapWSrU0YR9oH2aAXLvLo","searches":0,"confidence":"none","phrase":"kastrup atrium"},{"place":"ChIJ2Tfbg99D1moRVDB-DLpJuxk","searches":0,"confidence":"general","phrase":"kings club coworking"},{"place":"ChIJxUJgow8j0i0RjyKN1-EY-tU","searches":0,"confidence":"none","phrase":"kinodome ubud coworking"},{"place":"ChIJS_78wiYzGQ0RnCe0rFOyMCM","searches":30,"confidence":"city","phrase":"kiosk cafe lisbon"},{"place":"ChIJxROCUU-tU0YRBurHIUamlBw","searches":0,"confidence":"none","phrase":"kloverbyens kontorfaellesskab"},{"place":"ChIJd4gQaPBC1moRGZxE0bHtibU","searches":0,"confidence":"none","phrase":"knock knock cowork"},{"place":"ChIJbdt4Oap5nEcRloCWc22dAMY","searches":0,"confidence":"none","phrase":"konditorei brommler rottachstrasse"},{"place":"ChIJL0tsm6NTUkYRXW-JQ_fQZNc","searches":80,"confidence":"unsure","phrase":"kontor frederiksberg"},{"place":"ChIJuwzpedlTUkYRoPlaaX3fEW4","searches":0,"confidence":"none","phrase":"kontoret nyvej 16 c"},{"place":"ChIJN9cUwBFTUkYRQPfUhxKt4fg","searches":0,"confidence":"none","phrase":"kontoret pa gammeltorv"},{"place":"ChIJsReAMQZTUkYR7ghiWcs_PWs","searches":0,"confidence":"none","phrase":"kontoret vestergade 16"},{"place":"ChIJR71uw3ZTUkYRj65tk-jGAN4","searches":0,"confidence":"none","phrase":"kontorfaelleskabet valby tag"},{"place":"ChIJ7TXAeCJTUkYROcpfQp5sZRE","searches":0,"confidence":"none","phrase":"kontorfaellesskab i bredgade 30"},{"place":"ChIJu9yakf9TUkYRYiRrgVikPYA","searches":0,"confidence":"none","phrase":"kontorfaellesskab pa bredgade 45b"},{"place":"ChIJeTAWUaVTUkYRmRDDnZ7IYKk","searches":40,"confidence":"unsure","phrase":"kronprinsessegade 26"},{"place":"ChIJDdMI33RTUkYRY7U7rZqbXxY","searches":0,"confidence":"none","phrase":"kryptonit specialekontor"},{"place":"ChIJSSq4i74zGQ0RuoAgIFj3wKU","searches":360,"confidence":"sure","phrase":"kube coworking"},{"place":"ChIJVy5fj5k0GQ0R6t-dYcu9qSg","searches":80,"confidence":"city","phrase":"lacs lisbon"},{"place":"ChIJJxpVxz5lJA0RuQjlpZaBOW8","searches":800,"confidence":"sure","phrase":"lacs porto"},{"place":"ChIJAeFYXig1GQ0RgQXSgG5VYt8","searches":480,"confidence":"sure","phrase":"lacs santos"},{"place":"ChIJj1OxEZVYnEcRhlUiMgruquk","searches":0,"confidence":"none","phrase":"landhotel huberhof gmbh co kg"},{"place":"ChIJWfV0bQBd1moRxtARTQv_H-4","searches":0,"confidence":"none","phrase":"lennon mills co working"},{"place":"ChIJL8GQ_8s4u0cR7wcCpqitINQ","searches":0,"confidence":"none","phrase":"leo lernort"},{"place":"ChIJFUEQZrcCdkgRpNONQ8j7Nik","searches":430,"confidence":"sure","phrase":"level39"},{"place":"ChIJy_x1cm872jARHfjh8UwW3fw","searches":10,"confidence":"city","phrase":"life space chiang mai"},{"place":"ChIJ65g66AlTUkYRYDJC3yPiXRM","searches":0,"confidence":"none","phrase":"liftoff cph kontorfaellesskab"},{"place":"ChIJ18SvEI8zGQ0RIq_W9iOODIs","searches":10,"confidence":"sure","phrase":"lisbon business center"},{"place":"ChIJIQ87rNgzGQ0R5MIOd_SwMOE","searches":60,"confidence":"sure","phrase":"lisbon workhub"},{"place":"ChIJz8TMl7M72jAROjHcw9Mgyko","searches":20,"confidence":"unsure","phrase":"little big space"},{"place":"ChIJre0HxXIbdkgRlKNKc6qB0a8","searches":420,"confidence":"sure","phrase":"loom club"},{"place":"ChIJOe7WKz9D1moRe-5yoc4xmo8","searches":0,"confidence":"none","phrase":"m cloft"},{"place":"ChIJSym02KDvGRMRCFXdA8gZEkM","searches":0,"confidence":"general","phrase":"magnisi"},{"place":"ChIJJbrWQ8tVUkYRO_zL6RClass","searches":0,"confidence":"general","phrase":"magnoliahus"},{"place":"ChIJV-3xxRRTUkYRu8RxzMBA4k4","searches":10,"confidence":"city","phrase":"maker copenhagen"},{"place":"ChIJ6Rc-1A8j0i0RkOmhCUSUYSg","searches":0,"confidence":"none","phrase":"manditya homestay"},{"place":"ChIJuWOvJ1_LHg0Ryq3sShrGqzw","searches":0,"confidence":"general","phrase":"marketline"},{"place":"ChIJjw55n4w90i0R8FNp1w48uhI","searches":0,"confidence":"general","phrase":"mediafun"},{"place":"ChIJs8WOodNC1moRuLYs7WdsT9M","searches":100,"confidence":"sure","phrase":"melbourne accelerator program"},{"place":"ChIJA8KuFyND1moRk6qifP1SwH4","searches":10,"confidence":"sure","phrase":"melbourne connect co working"},{"place":"ChIJqXR-17JD1moRUodBC3UMjyk","searches":40,"confidence":"sure","phrase":"melbourne therapy rooms"},{"place":"ChIJ6UuT2k5TUkYRhP2CSpLoIKs","searches":30,"confidence":"city","phrase":"minas kaffebar copenhagen"},{"place":"ChIJWWYduTGjU0YRtrn1x9kaAVU","searches":0,"confidence":"none","phrase":"mindpark malmo city"},{"place":"ChIJ32Cr7wehU0YR9hEj9ybRSs4","searches":0,"confidence":"none","phrase":"mindpark malmo hyllie eden"},{"place":"ChIJp5ehuop1nkcRnJozACdh_Rg","searches":250,"confidence":"unsure","phrase":"mindspace viktualienmarkt"},{"place":"ChIJZ_qkodfzm0cRAkli1PSwUbk","searches":0,"confidence":"none","phrase":"mmco work"},{"place":"ChIJoRcI4M83GQ0R6h_Nmi2DkoI","searches":200,"confidence":"unsure","phrase":"moinho novo"},{"place":"ChIJe8kMiPYzGQ0R06IYbzg5xxo","searches":80,"confidence":"unsure","phrase":"monday marques de pombal"},{"place":"ChIJP6GGMzMnHw0R5pTPytpw_9U","searches":10,"confidence":"sure","phrase":"mother cafe ericeira"},{"place":"ChIJA45DFtbMHg0RZUoq041zv7s","searches":0,"confidence":"none","phrase":"mu workspace lisboa"},{"place":"ChIJY8LClUl3nkcRSEvMMR-bhSU","searches":800,"confidence":"sure","phrase":"munich urban colab"},{"place":"ChIJhWPUUAND1moRiNfDLq0atPM","searches":300,"confidence":"unsure","phrase":"mycelium studios"},{"place":"ChIJLXAs0bEzGQ0RYJSduW5COqo","searches":0,"confidence":"none","phrase":"nau coworking"},{"place":"ChIJC1srHkKpGA0Rk-yNW1Yv5m8","searches":0,"confidence":"general","phrase":"nazare coworking"},{"place":"ChIJw91WIo3lGRMRm7E3r1aHMG8","searches":20,"confidence":"unsure","phrase":"neu noi"},{"place":"ChIJmZGSewB5nEcR_euTMLdGhWY","searches":0,"confidence":"none","phrase":"neue areal"},{"place":"ChIJzdzIP81n1moRaM7CACU-hG8","searches":0,"confidence":"none","phrase":"newport foundry"},{"place":"ChIJ__-P5UND1moRxe5PbadWq0Y","searches":0,"confidence":"none","phrase":"nicholson street studios"},{"place":"ChIJwVC529TfnUcRQh-8hK30XPs","searches":0,"confidence":"none","phrase":"nicnoa co glockenbach"},{"place":"ChIJvYwh5Ep1nkcR74Z36SgnCFU","searches":0,"confidence":"none","phrase":"nicnoa co maxvorstadt"},{"place":"ChIJYypWbyEx2jARVuE38KVExYE","searches":0,"confidence":"none","phrase":"niecespace"},{"place":"ChIJ0e0bfEw72jARlAKZariIsK0","searches":0,"confidence":"general","phrase":"nim space"},{"place":"ChIJkZt6yQox2jAR4VEpgBb-xpo","searches":0,"confidence":"none","phrase":"niramis co creating space"},{"place":"ChIJUYHmAAMxGQ0RouEhls1KO90","searches":0,"confidence":"general","phrase":"nkoowoork"},{"place":"ChIJt3g89ABTUkYR09uDzrulTU4","searches":470,"confidence":"sure","phrase":"nomad workspace"},{"place":"ChIJS3-1iC0nHw0Rk8BX0SI2ylo","searches":30,"confidence":"sure","phrase":"nomadico ericeira"},{"place":"ChIJgRNqBvcnHw0Rs9ehK4CqdfM","searches":0,"confidence":"sure","phrase":"nomads ericeira coworking space"},{"place":"ChIJX_K7dtdSUkYR2iJ_u8747NE","searches":0,"confidence":"none","phrase":"nordic bizz"},{"place":"ChIJWeEwVwAx2jARsEvyDuBa0Jo","searches":100,"confidence":"unsure","phrase":"number 03"},{"place":"ChIJV32ULCo1GQ0RsWGDeYSqskg","searches":0,"confidence":"general","phrase":"nuno space"},{"place":"ChIJ8Zx5Yn43Hw0RdClGZ1LhZpk","searches":0,"confidence":"general","phrase":"nuts"},{"place":"ChIJdR2H2Ik1GQ0R6ZVk0SdUue8","searches":410,"confidence":"sure","phrase":"o momento"},{"place":"ChIJe4RASF1D1moRBWYjfhqJsNU","searches":80,"confidence":"unsure","phrase":"o3 brunswick"},{"place":"ChIJ1SVFLa5bnEcRd4DyeI6M8eE","searches":0,"confidence":"none","phrase":"oakyard coworking and makerspace"},{"place":"ChIJ_aFGIqCpGA0RZfBb2GAKpaQ","searches":0,"confidence":"none","phrase":"octopus concept club"},{"place":"ChIJp3bKtVAzGQ0RsuTtG7oNz6w","searches":10,"confidence":"unsure","phrase":"office evolution entrecampos"},{"place":"ChIJFVLhOdfvGRMRjvhcBkxrsfI","searches":0,"confidence":"none","phrase":"office ora"},{"place":"ChIJs0qabUJn1moRpKUBqiIQJZM","searches":0,"confidence":"none","phrase":"officeours yarraville"},{"place":"ChIJ8w-GiwkzGQ0RW8Evoboc-TA","searches":0,"confidence":"general","phrase":"one leaf"},{"place":"ChIJcWn9G6A72jARGBmwugYzbqg","searches":80,"confidence":"sure","phrase":"one workspace"},{"place":"ChIJocWYIt8zGQ0RnOxVvOvKZYE","searches":10,"confidence":"unsure","phrase":"one your first stop"},{"place":"ChIJVQiYagCtGA0R47yFxUGBIAc","searches":0,"confidence":"none","phrase":"orca co work space"},{"place":"ChIJkVr76AWp2EcRT_b87-ioFbs","searches":100,"confidence":"city","phrase":"othership london"},{"place":"ChIJR8BYBzld1moRiKIEJO-2DRM","searches":60,"confidence":"unsure","phrase":"our community house"},{"place":"ChIJy46c8u8nHw0R0WKTLfzxyt8","searches":150,"confidence":"sure","phrase":"outsite ericeira"},{"place":"ChIJy4Kvvlc1GQ0Ri9RNrPZUNe0","searches":300,"confidence":"sure","phrase":"outsite lisbon"},{"place":"ChIJu26X8oIzGQ0RHXYrDunyvog","searches":0,"confidence":"none","phrase":"palma lab"},{"place":"ChIJY6Q0KJ8zGQ0RNhFrMeMaTbY","searches":350,"confidence":"unsure","phrase":"padaria do bairro"},{"place":"ChIJPwVdSrZp1moRrL6NSXcvJL4","searches":0,"confidence":"none","phrase":"paddock offices st kilda road"},{"place":"ChIJH3uhQ58zGQ0RrQhewM_2LZM","searches":0,"confidence":"none","phrase":"pastelaria leafar"},{"place":"ChIJB6j_A7pd1moR3u3wAzE8QKU","searches":0,"confidence":"none","phrase":"peak spaces"},{"place":"ChIJF2O9vVjvGRMRS3vzu4E_AVs","searches":0,"confidence":"none","phrase":"pmo colavoro"},{"place":"ChIJGXUgiu9D1moRqjeo454c28I","searches":0,"confidence":"none","phrase":"pob space"},{"place":"ChIJa95M3z0j0i0RZCvyGwUNmKQ","searches":0,"confidence":"none","phrase":"pondok perjuangan"},{"place":"ChIJ44dEc7Nc1moRfhsUsw1bke4","searches":0,"confidence":"none","phrase":"prentice street studio"},{"place":"ChIJY3fPMgCzGA0RpGCnVs7r_uA","searches":20,"confidence":"unsure","phrase":"prontos impact village"},{"place":"ChIJ7zaMXgCzGA0RID2dA7yNrFE","searches":20,"confidence":"unsure","phrase":"prontos impact village"},{"place":"ChIJe3a705Y50i0REJ_Ih0lzJ-c","searches":0,"confidence":"none","phrase":"proper sounds studio"},{"place":"ChIJ_0bPQAdTUkYRNOSA0bqeGnY","searches":110,"confidence":"sure","phrase":"props coffee shop"},{"place":"ChIJY49pQZuHm0cRKGGAMxRS6GI","searches":0,"confidence":"none","phrase":"purschwarz kaffeerosterei"},{"place":"ChIJA3OW7A0zGQ0RzYJ86P25MSQ","searches":0,"confidence":"none","phrase":"quartoescuro collective"},{"place":"ChIJ2bE7MdxlJA0RCBIsmFmC5Y0","searches":0,"confidence":"sure","phrase":"re work porto cowork"},{"place":"ChIJzweGQA072jARGF5UNe8GTAg","searches":0,"confidence":"general","phrase":"realspace coworking"},{"place":"ChIJZwlgC-dSUkYRE67Qww7Xx70","searches":0,"confidence":"general","phrase":"rebel work space"},{"place":"ChIJQUKXNjpPYA0RtcMbLn0k97A","searches":50,"confidence":"sure","phrase":"red coworking valencia"},{"place":"ChIJETBJPiUbdkgRqRXjuurmnrM","searches":700,"confidence":"city","phrase":"regus london"},{"place":"ChIJeeYEAIxlJA0RJeAxqPoD514","searches":100,"confidence":"city","phrase":"regus porto"},{"place":"ChIJdTuRRQtTUkYRwkDmSO5YcdI","searches":280,"confidence":"sure","phrase":"republikken"},{"place":"ChIJf5AgTiVo1moR0bOz6LMHkVI","searches":10,"confidence":"city","phrase":"revolver lane melbourne"},{"place":"ChIJU9_JTO1TUkYRv3qXm-DAq2o","searches":50,"confidence":"unsure","phrase":"ricco kaffe"},{"place":"ChIJwRfZ8EpSUkYRHuZfNWevxb4","searches":10,"confidence":"city","phrase":"rocket labs copenhagen"},{"place":"ChIJAQBQOFND1moRfSTHkg3u48c","searches":0,"confidence":"none","phrase":"rubato upstairs"},{"place":"ChIJQ3rCa_x1nkcREXLK7QcZmm4","searches":50,"confidence":"sure","phrase":"ruby leo workspaces munich"},{"place":"ChIJiyJPlJol0i0RtouOwkn59bM","searches":0,"confidence":"none","phrase":"rumah pak rika"},{"place":"ChIJ75v5PzplmUcR-runvbkD-EY","searches":0,"confidence":"none","phrase":"sprittwitz coworking space"},{"place":"ChIJY6Eoxmk72jARhj1za4yCZbY","searches":0,"confidence":"general","phrase":"sala space"},{"place":"ChIJNUJZYQA50i0RcPPTjEDV6HY","searches":0,"confidence":"none","phrase":"samada work life cafe"},{"place":"ChIJ130sp6I_u0cRkHZfg-ekj1U","searches":0,"confidence":"none","phrase":"satt glucklich im cafe hahn"},{"place":"ChIJT71T6nl1nkcRBpj4xomsHq8","searches":0,"confidence":"general","phrase":"scaling spaces"},{"place":"ChIJlVauV281GQ0RQFGZO7D4gng","searches":50,"confidence":"unsure","phrase":"scape workspaces"},{"place":"ChIJ1Sj0HwAl2jARkG9oayNUUSE","searches":0,"confidence":"none","phrase":"scg accounting services"},{"place":"ChIJ3xoeF9u3cUERXSsY4XvXUgM","searches":20,"confidence":"unsure","phrase":"science park kassel"},{"place":"ChIJORosawA90i0RpuTGhmSKx9E","searches":0,"confidence":"none","phrase":"sembari coworking coliving"},{"place":"ChIJvUBhMp5D1moRXKp5SXs4leY","searches":0,"confidence":"general","phrase":"service cowork"},{"place":"ChIJg5O0eg9lJA0RBRLhzosmqmw","searches":0,"confidence":"none","phrase":"shiftworkplace coworking"},{"place":"ChIJ6TbG5Eip2EcRo8n88ZaQHQ0","searches":210,"confidence":"sure","phrase":"silver building"},{"place":"ChIJE45DCbEzGQ0RejvsH1-_pHk","searches":90,"confidence":"unsure","phrase":"simpli coffee picoas"},{"place":"ChIJpxiDfWzLHg0RFQIWwRUBG40","searches":0,"confidence":"none","phrase":"sincera coworking"},{"place":"ChIJKby2B0szGQ0RG5IZ2uWkwwg","searches":0,"confidence":"none","phrase":"sitio aihub"},{"place":"ChIJP9WnVgszGQ0RxQwxbQN2b0o","searches":0,"confidence":"none","phrase":"sitio alto de sao joao cowork"},{"place":"ChIJc1FNG1UyGQ0R6poeQzrG6zY","searches":30,"confidence":"unsure","phrase":"sitio alvalade"},{"place":"ChIJw7IOgbQzGQ0Rr3vSrRtiYXM","searches":0,"confidence":"none","phrase":"sitio avenida"},{"place":"ChIJaV9JQBkzGQ0RiFiA-8QngfU","searches":30,"confidence":"unsure","phrase":"sitio fintech house"},{"place":"ChIJ41mX4fwzGQ0R8cafjYV_FMw","searches":70,"confidence":"unsure","phrase":"sitio rossio"},{"place":"ChIJgRD-Xw0zGQ0Rzop6SSD3iw8","searches":40,"confidence":"unsure","phrase":"sitio sete rios"},{"place":"ChIJ8d_WafpC1moRV-Kfxd1GONc","searches":0,"confidence":"none","phrase":"six8 bromham"},{"place":"ChIJ38BeHgdTUkYRxJ6ZG-QxaGI","searches":0,"confidence":"general","phrase":"skra"},{"place":"ChIJk_uqZbg1GQ0RuGAwe4VuzKk","searches":0,"confidence":"none","phrase":"slow coliving arrabida"},{"place":"ChIJSwjmdV1lJA0R5uoB4uFy5oA","searches":170,"confidence":"sure","phrase":"so coffee roasters"},{"place":"ChIJAeuuFWo72jARlV6oYdjMCmc","searches":0,"confidence":"none","phrase":"socialer coliving coworking space"},{"place":"ChIJ___b1Phn1moRDzhlsucMzZE","searches":0,"confidence":"none","phrase":"south hive"},{"place":"ChIJhbDSKWND1moRWj3I-UFGV8Q","searches":0,"confidence":"none","phrase":"spaces 222 hoddle street"},{"place":"ChIJGbmQXogDdkgRyl_bT4fdik8","searches":200,"confidence":"unsure","phrase":"spaces canary wharf"},{"place":"ChIJqz74H_xD1moRL8PoCqfDmTA","searches":0,"confidence":"general","phrase":"spaces collingwood"},{"place":"ChIJI5JFkDYFdkgRjVFK28OLtKM","searches":0,"confidence":"general","phrase":"spaces covent garden"},{"place":"ChIJp83PU-AbdkgRbENt3s2GJNw","searches":100,"confidence":"unsure","phrase":"spaces euston road"},{"place":"ChIJFRJZ1dUadkgRt0vcQIBo3dw","searches":0,"confidence":"general","phrase":"spaces fitzrovia"},{"place":"ChIJO4benMgzGQ0RWRlIzc4k5Rg","searches":250,"confidence":"unsure","phrase":"spaces marques de pombal"},{"place":"ChIJAwslW2EzGQ0Rbsa8fLfwUQM","searches":0,"confidence":"general","phrase":"spaces oriente"},{"place":"ChIJJX7HVJNF1moR74pwSzvIqJ0","searches":0,"confidence":"none","phrase":"spaces raglan street"},{"place":"ChIJcxaLpwdd1moRjfjZD1PIKPU","searches":90,"confidence":"sure","phrase":"spaces rialto"},{"place":"ChIJnZpQZ-dD1moR0qI7WeeoBe8","searches":0,"confidence":"general","phrase":"spaces richmond"},{"place":"ChIJKbHthNJd1moRjTAfBZ2Ae0I","searches":0,"confidence":"none","phrase":"spaces two mq"},{"place":"ChIJH3Bu7K1TUkYRA2BTHjDsOKE","searches":0,"confidence":"none","phrase":"specialeplads dk"},{"place":"ChIJ7bBHMgAzGQ0Rq9rLkV-T6vY","searches":40,"confidence":"city","phrase":"starbucks lisbon"},{"place":"ChIJ-T03eOFkJA0R4lhy9gJ_pGU","searches":450,"confidence":"city","phrase":"starbucks porto"},{"place":"ChIJ4YNX68tC1moRDHWwPzDBKy8","searches":0,"confidence":"general","phrase":"startspace"},{"place":"ChIJwTiqTSND1moROzMwbdQRvDE","searches":40,"confidence":"unsure","phrase":"stay soft studio"},{"place":"ChIJzfZfZ2tD1moRiqvle_m2HMg","searches":40,"confidence":"unsure","phrase":"stay soft studio"},{"place":"ChIJ77FMuDqtU0YRKh1DBFNNA7Q","searches":0,"confidence":"none","phrase":"studie124"},{"place":"ChIJjd4nP7Fd1moR_-oKP-2zwnY","searches":0,"confidence":"none","phrase":"super voxel world"},{"place":"ChIJrXzdXM4nHw0R5q7aXA2rGXI","searches":0,"confidence":"none","phrase":"surf work and more"},{"place":"ChIJ_9IQVUJSUkYRUL5gwjHtse4","searches":0,"confidence":"none","phrase":"symbion sterbro"},{"place":"ChIJZ5XmyfM9-AURcRuVL5Y8smA","searches":0,"confidence":"general","phrase":"synergy co"},{"place":"ChIJRd0NSF5D1moRtY-y7bmSo_E","searches":0,"confidence":"none","phrase":"t o m s place coworking"},{"place":"ChIJB3JUwGZd1moRtp0PyrQerqU","searches":0,"confidence":"none","phrase":"tailorbird studios"},{"place":"ChIJESTE8zJd1moR8W7UB1t7ozc","searches":40,"confidence":"sure","phrase":"tank stream labs melbourne"},{"place":"ChIJpbLKlBNTUkYRoMaiZLVVKBU","searches":0,"confidence":"general","phrase":"techstation"},{"place":"ChIJCfYeL6pTUkYRSKTfK9AZkcw","searches":0,"confidence":"none","phrase":"tegnestuen gimle"},{"place":"ChIJrex__CrfnUcRCKka4M-NLKQ","searches":0,"confidence":"none","phrase":"terra cafe tagesbar co working"},{"place":"ChIJoSUIuJdD1moRo6mJatw32CM","searches":0,"confidence":"general","phrase":"terra coworking"},{"place":"ChIJz80fyphD1moRp1N-xcvlR3M","searches":0,"confidence":"none","phrase":"the 365 serviced office co working space"},{"place":"ChIJ076Kd6pvn48R6bCv-M_n4GA","searches":0,"confidence":"general","phrase":"the ark house"},{"place":"ChIJH0ZFmTr1nEcRevLBBDf7Fcc","searches":0,"confidence":"none","phrase":"the blue studio coworking"},{"place":"ChIJk-_5cyIbdkgRPLFEHaYCpew","searches":260,"confidence":"sure","phrase":"the boutique workplace company"},{"place":"ChIJvbE_bF0x2jARFsvGBwlFLLg","searches":0,"confidence":"none","phrase":"the brick x"},{"place":"ChIJZeUhpus90i0Rm2E4a-xRdpY","searches":0,"confidence":"none","phrase":"the bridge green school"},{"place":"ChIJlRMXcDsbdkgRJdsP3nlUkBg","searches":1000,"confidence":"city","phrase":"the british library london"},{"place":"ChIJo1z8_241GQ0RZxl_7-lVCdY","searches":0,"confidence":"general","phrase":"the clubhouse"},{"place":"ChIJ819sz0xd1moRDzEH4_QkEDE","searches":870,"confidence":"sure","phrase":"the cluster"},{"place":"ChIJ1_S1trA72jARF7oXy2uAU6U","searches":360,"confidence":"sure","phrase":"the coco club"},{"place":"ChIJkU8hmRVD1moRu7o9UfCHAEI","searches":20,"confidence":"unsure","phrase":"the commons collins street"},{"place":"ChIJeU7ihJRD1moRjhsOfBQP9XM","searches":0,"confidence":"none","phrase":"the commons cremorne street"},{"place":"ChIJMxBlhOFC1moRUj08WlPH0os","searches":30,"confidence":"unsure","phrase":"the commons gipps street"},{"place":"ChIJGXD8qOxD1moRwKM0tfnDmoA","searches":0,"confidence":"none","phrase":"the commons gwynne street"},{"place":"ChIJs_Jjef9n1moRj3fubU0FpWw","searches":0,"confidence":"none","phrase":"the commons market street"},{"place":"ChIJD83anCtD1moRELOkn5W1boE","searches":200,"confidence":"unsure","phrase":"the commons qv"},{"place":"ChIJs6nQIylD1moRsZfKiER3HNI","searches":0,"confidence":"none","phrase":"the commons toorak road"},{"place":"ChIJ6b63j41D1moRdU4rknYP0ok","searches":150,"confidence":"unsure","phrase":"the commons wellington street"},{"place":"ChIJCxZuSVZp1moRo6wPnunkXz4","searches":0,"confidence":"none","phrase":"the commons wilson street"},{"place":"ChIJe6r3zVk50i0RSyOUSS4Gnd4","searches":0,"confidence":"none","phrase":"the decision table coworking"},{"place":"ChIJx0jlQKUzGQ0Rv2jGR0H0o0s","searches":0,"confidence":"none","phrase":"the food tech hub"},{"place":"ChIJC0WDaPAzGQ0RxRdn2MNKusE","searches":0,"confidence":"none","phrase":"the fyve"},{"place":"ChIJNfIcNxBpnEcRdz38NuYGs3c","searches":0,"confidence":"none","phrase":"the green room coworking"},{"place":"ChIJaRmLQVJp1moR8_JUZDnRkd4","searches":30,"confidence":"unsure","phrase":"the hive milton house"},{"place":"ChIJsxjtQIxd1moRc8WsIn5Xm7w","searches":0,"confidence":"general","phrase":"the idea collective"},{"place":"ChIJjxK_pAZTUkYR3DSmcXDnjlc","searches":60,"confidence":"city","phrase":"the library copenhagen"},{"place":"ChIJpdeQ-phD1moRkzXThZ9exuI","searches":90,"confidence":"unsure","phrase":"the loft workspaces"},{"place":"ChIJk__ztzxd1moRhz0Y1PcfIYY","searches":0,"confidence":"general","phrase":"the mezzanine"},{"place":"ChIJgVtIlwAzGQ0R13r5CFZjEIQ","searches":0,"confidence":"none","phrase":"the nest by near"},{"place":"ChIJ4av-ej5D1moRevK89K2GQrs","searches":0,"confidence":"none","phrase":"the north collective"},{"place":"ChIJVYVPPjOp2EcRdif0gYoSbUQ","searches":20,"confidence":"city","phrase":"the pump house london"},{"place":"ChIJZVdHqSljnEcReJYDGCNwR2U","searches":0,"confidence":"none","phrase":"the red loft coworking"},{"place":"ChIJe6ZUF0E72jARmXaUbJ9QmtU","searches":10,"confidence":"sure","phrase":"the social club chiang mai"},{"place":"ChIJE-An1ghTUkYReG3cmlFSza0","searches":0,"confidence":"none","phrase":"the union workspaces nordhavn"},{"place":"ChIJSXkoEyYbdkgRpmQAturmT2k","searches":2050,"confidence":"sure","phrase":"the wesley euston"},{"place":"ChIJVwiAn6f1nEcRMjL4hSFjk7s","searches":0,"confidence":"none","phrase":"the white lake coworking"},{"place":"ChIJHTAWjPYnHw0R70QmLlxQWPA","searches":10,"confidence":"unsure","phrase":"tiger chick"},{"place":"ChIJN6Fw0KhTUkYRLUZivgCs8gE","searches":250,"confidence":"unsure","phrase":"tjili pop"},{"place":"ChIJkcYYKxQzGQ0RSm5HgPAIOVU","searches":90,"confidence":"unsure","phrase":"tomorrow at 9 cafe"},{"place":"ChIJvQkyxwczGQ0RuQiGtYZUufA","searches":0,"confidence":"none","phrase":"too cool for school co working space beauty"},{"place":"ChIJXUrxcd1TUkYRR6Msn3m4mEc","searches":0,"confidence":"none","phrase":"toto kontorfaellesskab"},{"place":"ChIJRfly8KBnmUcRLlQciY1WoKc","searches":0,"confidence":"general","phrase":"trooms"},{"place":"ChIJr_UcdvKf4jARG1xTUbtlPbI","searches":300,"confidence":"unsure","phrase":"true space asoke"},{"place":"ChIJ3Uwy34rLHg0RxadyqEedM60","searches":0,"confidence":"general","phrase":"trullino"},{"place":"ChIJ_TB7W8tIYA0RehAJfTOFFVg","searches":0,"confidence":"none","phrase":"ubik cafe cafeteria libreria"},{"place":"ChIJae1GeQA90i0Rtm1A0HtRhgI","searches":20,"confidence":"unsure","phrase":"ubud co working"},{"place":"ChIJn_svTlZSUkYRSi1TaZ4QZhc","searches":0,"confidence":"none","phrase":"ucph innovation hub"},{"place":"ChIJeUokKdIzGQ0RuTgBCilDKr4","searches":0,"confidence":"none","phrase":"unicorn workspaces avenidas novas"},{"place":"ChIJId9wjfMzGQ0RZ4v_vUn6_Fs","searches":0,"confidence":"none","phrase":"unicorn workspaces liberdade"},{"place":"ChIJNSvJwBhD1moReqAVfggX75g","searches":520,"confidence":"sure","phrase":"united co"},{"place":"ChIJIRyzfPijU0YRrCuheHj8SZI","searches":0,"confidence":"none","phrase":"united spaces malmo"},{"place":"ChIJ-xe8rApTUkYRr1kcYXtdvXo","searches":0,"confidence":"none","phrase":"v74 coworking space"},{"place":"ChIJqYdiepKtU0YRkFx-KvBZsNA","searches":0,"confidence":"none","phrase":"va11a coworking"},{"place":"ChIJt80znI4DdkgRqabveK1knwE","searches":0,"confidence":"none","phrase":"veloa space"},{"place":"ChIJJ56g4l7vGRMRn6ncOYDMiGs","searches":700,"confidence":"unsure","phrase":"vera coffice break"},{"place":"ChIJZaGA0RJlJA0RsTTbFwyqhjE","searches":0,"confidence":"none","phrase":"vertical coworking bolhao"},{"place":"ChIJ5TYRVkNlJA0RTFU8OOfiDDI","searches":60,"confidence":"unsure","phrase":"vertical coworking firmeza"},{"place":"ChIJ87PIF_BSUkYRqkAok2_taVk","searches":250,"confidence":"unsure","phrase":"villa kultur"},{"place":"ChIJKRJu3paL0S0RIHQ0HRFmyHg","searches":0,"confidence":"none","phrase":"vip room baps"},{"place":"ChIJ0Wsn6gFRUkYRmBvnKzpkwFM","searches":0,"confidence":"none","phrase":"visionhouse rodovre"},{"place":"ChIJn3DdA4lPYA0RI8OJw1quv3A","searches":0,"confidence":"general","phrase":"vital coworking"},{"place":"ChIJxdXcmp5p1moR-l2D2vGTGJ0","searches":0,"confidence":"general","phrase":"w hub"},{"place":"ChIJ3dvGNMRD1moRcr3pAq918WY","searches":30,"confidence":"unsure","phrase":"waterman abbotsford"},{"place":"ChIJvUt4aEZD1moRI_hPR4kH8OM","searches":170,"confidence":"sure","phrase":"waterman collins street"},{"place":"ChIJCeQ-q4Fd1moRu0ismdBotns","searches":100,"confidence":"unsure","phrase":"waterman moonee ponds"},{"place":"ChIJm0W58VRD1moRnD31J_mgMP4","searches":30,"confidence":"unsure","phrase":"waterman richmond vic gardens"},{"place":"ChIJ1dnQVJhD1moR4-2t7GIcAMQ","searches":90,"confidence":"unsure","phrase":"waterman south yarra"},{"place":"ChIJjwAL8SUbdkgRigNbhm-sUe0","searches":800,"confidence":"city","phrase":"wellcome collection london"},{"place":"ChIJKQNtg211nkcRkJL-oPe0wlc","searches":300,"confidence":"city","phrase":"wework munich"},{"place":"ChIJ_WpGcqcbdkgRjFAvoaxK2wk","searches":2300,"confidence":"city","phrase":"wework london"},{"place":"ChIJ965gFbUEdkgRdDo6c8CnHaU","searches":2300,"confidence":"city","phrase":"wework london"},{"place":"ChIJl2xsELgEdkgR4DI-EZp299s","searches":2300,"confidence":"city","phrase":"wework london"},{"place":"ChIJH5p8i1AbdkgRD01IW5aTTS4","searches":2300,"confidence":"city","phrase":"wework london"},{"place":"ChIJOUuemuRTUkYRQdLFZp9ngk8","searches":0,"confidence":"general","phrase":"wharf"},{"place":"ChIJp-d4GEw_u0cRaTP83PxPNjQ","searches":20,"confidence":"unsure","phrase":"wok work oase kassel"},{"place":"ChIJgUikJeJTUkYR0sLFJ8bv0Bw","searches":50,"confidence":"city","phrase":"work copenhagen"},{"place":"ChIJ1RNy_X0zGQ0Rma4pgDh3QOA","searches":0,"confidence":"none","phrase":"work avenida estrela"},{"place":"ChIJHyNV9klF1moRbCzz1PUkU0o","searches":0,"confidence":"none","phrase":"work by amber"},{"place":"ChIJzfyPbHszGQ0RkNcJZeLL7n4","searches":0,"confidence":"general","phrase":"work cafe santander"},{"place":"ChIJu41OiwND1moRFmXULpb7OwM","searches":20,"confidence":"unsure","phrase":"work club botanic gardens"},{"place":"ChIJxzmBmPVd1moRT_vEbh1B47s","searches":0,"confidence":"general","phrase":"work club olderfleet"},{"place":"ChIJyb9HV2NH0i0RiKLk5M2Vqeo","searches":0,"confidence":"none","phrase":"work hub coworking space"},{"place":"ChIJL3bLjQ0zGQ0RmJ_S5TYXhIU","searches":0,"confidence":"none","phrase":"work 380"},{"place":"ChIJp_FW-FAbdkgRTwKkDiXTCyU","searches":0,"confidence":"none","phrase":"workhub madesimple"},{"place":"ChIJ__8Qi3g40i0R8MMtZFPoSpo","searches":0,"confidence":"none","phrase":"workmates coworking space and cafe canggu by wonderspace"},{"place":"ChIJR5rX0R5D1moR1w4nN3JInAM","searches":0,"confidence":"none","phrase":"workplace cowork"},{"place":"ChIJ0YiE5RhD1moRgayTOZbsAvQ","searches":0,"confidence":"general","phrase":"worksmith"},{"place":"ChIJ3Zjhh-AyGQ0ROi3sIcEPGxk","searches":0,"confidence":"general","phrase":"workup"},{"place":"ChIJEZ-sgVpTUkYRjY9AxCAfbrA","searches":0,"confidence":"general","phrase":"workzoku"},{"place":"ChIJwX9_m9BRUkYRGPvQyP75-Y0","searches":0,"confidence":"none","phrase":"worq gladsaxe"},{"place":"ChIJ3cm0cg1d1moRFEARjcs-idg","searches":0,"confidence":"none","phrase":"wtc biz hub"},{"place":"ChIJ6euOd5EbdkgR-ZhZuSBEAAs","searches":0,"confidence":"none","phrase":"x why bloomsbury house"},{"place":"ChIJTXJgBEpp1moRnAwjKKUM9pQ","searches":0,"confidence":"none","phrase":"yellow desk coworking"},{"place":"ChIJKcLmdNYadkgR6-u569TK_xc","searches":300,"confidence":"sure","phrase":"yha london central hostel"},{"place":"ChIJmT587ORD1moRJ7BNLv4eEoY","searches":0,"confidence":"general","phrase":"zeno space"},{"place":"ChIJNZ9ODQgx2jAR6ihXCNj7gL8","searches":0,"confidence":"none","phrase":"zinme teahouse cowork"},{"place":"ChIJTzYO3U0l2jARw7WLM730AIw","searches":0,"confidence":"none","phrase":""},{"place":"ChIJ1SZveZQx2jARAaedTAf9EhM","searches":0,"confidence":"none","phrase":""},{"place":"ChIJ9b_TYbabfDURm77inYjvqhg","searches":0,"confidence":"none","phrase":"goyang artist residency saedeul"},{"place":"ChIJe4LSpwuFfDURtkpA2scrbqU","searches":0,"confidence":"none","phrase":"goyang artist residency haeum"},{"place":"ChIJDV8MeMqafDURDL3NCKH8DKE","searches":0,"confidence":"general","phrase":"102"},{"place":"ChIJf3y-11qFfDURqJmwqikE47A","searches":0,"confidence":"none","phrase":""},{"place":"ChIJX9N_LwSXfDURBcmC965ByKM","searches":0,"confidence":"none","phrase":""},{"place":"ChIJTwUcqeSFfDURNIKBwYKiAOA","searches":0,"confidence":"none","phrase":""},{"place":"ChIJF2nA3TWFfDURNQ1flzbyAwI","searches":0,"confidence":"none","phrase":""}]$demand$::jsonb, date '2026-10-05');
