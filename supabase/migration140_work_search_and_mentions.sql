-- ============================================================
-- Migration 140: two new kinds of evidence for a candidate.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026: "I need to be more confident a cafe on the
-- list is a strong likelihood as a good spot to pull out your laptop",
-- and "review competitor websites and other leading blogs that mention
-- cafes and coworking spaces, and then screen them to make sure they
-- are still open for business".
--
-- Until now the only sign was what Google's five reviews of a place
-- say. This adds two signs that draw on far more:
--
--   1. Google's own search. The nightly job (scripts/place_evidence.py)
--      asks Google for "laptop friendly cafe" and "cafe to work from"
--      in each city with a city page and keeps which places come back
--      (discovered_places.work_phrases). Google answers from all of a
--      place's reviews and details, not five. A place it returns that
--      was not known yet is added, so it also finds new candidates.
--
--   2. Other sites. A session reads competitor directories and blogs
--      and loads the places they name (place_mentions), with where
--      each was read (mention_sources). The nightly job matches each
--      name to a place: first against the spaces and found places we
--      already have (free), then by asking Google, which also says
--      whether it is still open. A closed place is marked closed and
--      never reaches Candidates.
--
-- admin_candidates() carries both on each row, counts them in "best
-- bets first", lets a place onto the list on their strength alone, and
-- sums up what the other sites name (mention_summary).
--
-- Nothing here writes to a space or the website.
-- ============================================================

-- -------------------------------------------- 0. how much may be asked

-- Jonathan, 5 Oct 2026: keep this inside Google's free allowance, with
-- room left for what the app and the other jobs use. Quality before
-- quantity while the flow is being got right.
--
-- Google gives each kind of call a free amount a month. These calls
-- are all of one kind, "Text Search Pro": 5,000 free a month (the
-- fields asked for are chosen to stay on it; the rating, which would
-- make it the dearer "Enterprise" kind with 1,000 free, is left to
-- the review scan). The settings, in sync_settings 'place_evidence':
--
--   cities          the cities worked on (their city page's name)
--   min_points      a named place is checked when its sites add up to
--                   this (a trusted list counts 2, an ordinary one 1)
--   calls_per_run   at most this many calls a day (the job runs at
--                   night, and again when its file changes on GitHub)
--   calls_per_month at most this many calls a month for this job
--   free_per_month  Google's free amount for the kind of call
--   keep_back       the part of the free amount this job never
--                   touches, left for the app and the other jobs
--
-- To widen it later, for example:
--   update public.sync_settings
--      set value = value || '{"cities": ["London", "Lisbon"]}'::jsonb
--    where key = 'place_evidence';
insert into public.sync_settings (key, value, updated_at)
values ('place_evidence',
        '{"cities": ["London"], "min_points": 2, "calls_per_run": 40,
          "calls_per_month": 1000, "free_per_month": 5000,
          "keep_back": 1500}'::jsonb, now())
on conflict (key) do nothing;

-- What may be asked of Google now: the settings, what this month has
-- used (this job, and everyone on the same kind of call), and what is
-- left: for the month, and for this run.
create or replace function public.evidence_plan()
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (
    select coalesce((select value from public.sync_settings
                      where key = 'place_evidence'), '{}'::jsonb) as v
  ),
  n as (
    select case when (v ->> 'min_points') ~ '^[0-9]{1,2}$'
                then (v ->> 'min_points')::integer else 2 end as min_points,
           case when (v ->> 'calls_per_run') ~ '^[0-9]{1,5}$'
                then (v ->> 'calls_per_run')::integer else 40 end as per_run,
           case when (v ->> 'calls_per_month') ~ '^[0-9]{1,6}$'
                then (v ->> 'calls_per_month')::integer else 1000 end as per_month,
           case when (v ->> 'free_per_month') ~ '^[0-9]{1,6}$'
                then (v ->> 'free_per_month')::integer else 5000 end as free,
           case when (v ->> 'keep_back') ~ '^[0-9]{1,6}$'
                then (v ->> 'keep_back')::integer else 1500 end as keep_back,
           -- no list at all means London, the first city
           case when jsonb_typeof(v -> 'cities') = 'array'
                then (select coalesce(jsonb_agg(lower(btrim(c))), '[]'::jsonb)
                        from jsonb_array_elements_text(v -> 'cities') c
                       where btrim(c) <> '')
                else '["london"]'::jsonb end as cities
      from s
  ),
  u as (
    select coalesce(sum(a.calls) filter (where a.sku = 'Text Search Pro'), 0)::integer
             as used_all,
           coalesce(sum(a.calls) filter (where a.source = 'candidate evidence'), 0)::integer
             as used_job,
           coalesce(sum(a.calls) filter (
             where a.source = 'candidate evidence'
               and a.day = (now() at time zone 'utc')::date), 0)::integer
             as used_today
      from public.api_usage a
     where a.day >= date_trunc('month', now() at time zone 'utc')::date
       and a.sku like 'Text Search%'
  )
  select jsonb_build_object(
           'kind', 'Text Search Pro',
           'cities', n.cities,
           'min_points', n.min_points,
           'calls_per_run', n.per_run,
           'calls_per_month', n.per_month,
           'free_per_month', n.free,
           'keep_back', n.keep_back,
           'used_job', u.used_job,
           'used_today', u.used_today,
           'used_all', u.used_all,
           'left_month', greatest(0, least(n.per_month - u.used_job,
                                           n.free - n.keep_back - u.used_all)),
           'left_run', greatest(0, least(n.per_run - u.used_today,
                                         n.per_month - u.used_job,
                                         n.free - n.keep_back - u.used_all)))
    from n, u
$$;
revoke all on function public.evidence_plan() from public, anon, authenticated;
grant execute on function public.evidence_plan() to service_role;

-- The job can be switched off by itself on the Google calls page.
create or replace function public.admin_set_google_control(p_key text, p_value numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  if p_key = 'places_gbp_per_day' then
    if p_value is null or p_value < 1 or p_value > 500 then
      raise exception '%', E'The daily limit must be between \u00a31 and \u00a3500.';
    end if;
  elsif p_key in ('pause:nightly refresh', 'pause:website sync',
                  'pause:website push', 'pause:photo suggestions',
                  'pause:photo check', 'pause:app',
                  'pause:candidate evidence') then
    p_value := case when coalesce(p_value, 0) >= 1 then 1 else 0 end;
  else
    raise exception 'Unknown setting.';
  end if;
  insert into public.api_limits (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return public.google_budget();
end $$;
revoke all on function public.admin_set_google_control(text, numeric) from public, anon;
grant execute on function public.admin_set_google_control(text, numeric) to authenticated;

-- ------------------------------------------------ 1. Google's search

alter table public.discovered_places
  add column if not exists work_phrases     text[],
  add column if not exists work_rank        integer,
  add column if not exists work_region      text,
  add column if not exists work_searched_at timestamptz;

-- When each city was last asked, and what came back.
create table if not exists public.work_searches (
  region_id   text primary key,
  name        text,
  searched_at timestamptz not null default now(),
  calls       integer not null default 0,
  found       integer not null default 0,
  added       integer not null default 0
);
alter table public.work_searches enable row level security;
drop policy if exists "work_searches admin" on public.work_searches;
create policy "work_searches admin" on public.work_searches
  for select to authenticated using (public.is_admin());

-- The cities to ask about now: among the cities worked on (the
-- settings above), the city pages people search for (region_search,
-- migration 137), never asked or asked more than 120 days ago, the
-- most searched first.
create or replace function public.work_search_due(p_limit integer default 10)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'region_id', x.id, 'name', x.name, 'country', x.country,
           'lat', x.lat, 'lng', x.lng) order by x.rn), '[]'::jsonb)
    from (select r.id, r.name, nullif(btrim(r.country), '') as country,
                 r.lat, r.lng,
                 row_number() over (
                   order by (ws.searched_at is not null), ws.searched_at,
                            coalesce(rs.coworking, 0) + coalesce(rs.cafes, 0) desc,
                            r.name, r.id) as rn
            from public.webflow_regions r
            join public.region_search rs on rs.region = lower(btrim(r.name))
            left join public.work_searches ws on ws.region_id = r.id
           where r.lat is not null and r.lng is not null
             and (public.evidence_plan() -> 'cities') ? lower(btrim(r.name))
             and (ws.searched_at is null
                  or ws.searched_at < now() - interval '120 days')) x
   where x.rn <= greatest(0, least(coalesce(p_limit, 10), 50))
$$;
revoke all on function public.work_search_due(integer) from public, anon, authenticated;
grant execute on function public.work_search_due(integer) to service_role;

-- The nightly job writes what Google returned for one city. Each row:
-- {"id", "name", "lat", "lng", "primary_type", "rating",
--  "user_rating_count", "address", "phrases": ["laptop friendly cafe"],
--  "rank": 3}. A place not known yet is added. A place marked for this
-- city before that Google no longer returns loses its mark.
create or replace function public.record_work_search(
  p_region text, p_name text, p_calls integer, p_rows jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n_found integer := 0;
  n_added integer := 0;
begin
  if coalesce(btrim(p_region), '') = '' then
    raise exception 'no city given';
  end if;

  create temporary table if not exists _work_rows (
    id text primary key, name text, lat double precision, lng double precision,
    primary_type text, rating numeric, user_rating_count integer,
    address text, phrases text[], rank integer) on commit drop;
  truncate _work_rows;

  if p_rows is not null and jsonb_typeof(p_rows) = 'array' then
    insert into _work_rows
    select distinct on (btrim(e ->> 'id'))
           btrim(e ->> 'id'),
           left(coalesce(nullif(btrim(e ->> 'name'), ''), 'Unnamed'), 300),
           (e ->> 'lat')::double precision,
           (e ->> 'lng')::double precision,
           nullif(btrim(coalesce(e ->> 'primary_type', '')), ''),
           case when (e ->> 'rating') ~ '^[0-9](\.[0-9]+)?$'
                then (e ->> 'rating')::numeric end,
           case when (e ->> 'user_rating_count') ~ '^[0-9]{1,9}$'
                then (e ->> 'user_rating_count')::integer end,
           nullif(left(btrim(coalesce(e ->> 'address', '')), 200), ''),
           (select array_agg(distinct left(btrim(ph), 60))
              from jsonb_array_elements_text(
                     case when jsonb_typeof(e -> 'phrases') = 'array'
                          then e -> 'phrases' else '[]'::jsonb end) ph
             where btrim(ph) <> ''),
           case when (e ->> 'rank') ~ '^[0-9]{1,4}$' then (e ->> 'rank')::integer end
      from jsonb_array_elements(p_rows) e
     where jsonb_typeof(e) = 'object'
       and coalesce(btrim(e ->> 'id'), '') <> ''
       and (e ->> 'lat') ~ '^-?[0-9]{1,3}(\.[0-9]+)?$'
       and (e ->> 'lng') ~ '^-?[0-9]{1,3}(\.[0-9]+)?$'
     order by btrim(e ->> 'id');
    delete from _work_rows where phrases is null;
  end if;

  select count(*) into n_found from _work_rows;
  select count(*) into n_added from _work_rows w
   where not exists (select 1 from public.discovered_places d
                      where d.google_place_id = w.id)
     and not exists (select 1 from public.venues v
                      where v.google_place_id = w.id);

  -- no longer returned for this city
  update public.discovered_places d
     set work_phrases = null, work_rank = null, work_searched_at = now()
   where d.work_region = p_region
     and not exists (select 1 from _work_rows w where w.id = d.google_place_id);

  insert into public.discovered_places as d
    (google_place_id, name, lat, lng, primary_type, rating, user_rating_count,
     address, work_phrases, work_rank, work_region, work_searched_at)
  select w.id, w.name, w.lat, w.lng, w.primary_type, w.rating,
         w.user_rating_count, w.address, w.phrases, w.rank, p_region, now()
    from _work_rows w
   -- a space already on Nomad Maps is not a found place
   where not exists (select 1 from public.venues v where v.google_place_id = w.id)
  on conflict (google_place_id) do update
    set work_phrases      = excluded.work_phrases,
        work_rank         = excluded.work_rank,
        work_region       = excluded.work_region,
        work_searched_at  = excluded.work_searched_at,
        address           = coalesce(nullif(btrim(d.address), ''), excluded.address),
        rating            = coalesce(excluded.rating, d.rating),
        user_rating_count = coalesce(excluded.user_rating_count, d.user_rating_count);

  insert into public.work_searches (region_id, name, searched_at, calls, found, added)
  values (p_region, p_name, now(), greatest(coalesce(p_calls, 0), 0), n_found, n_added)
  on conflict (region_id) do update
    set name = excluded.name, searched_at = excluded.searched_at,
        calls = excluded.calls, found = excluded.found, added = excluded.added;

  return n_found;
end $$;
revoke all on function public.record_work_search(text, text, integer, jsonb)
  from public, anon, authenticated;
grant execute on function public.record_work_search(text, text, integer, jsonb)
  to service_role;

-- --------------------------------------------- 2. what other sites name

-- A name as two sites would both write it: lower case, accents and
-- punctuation gone, "&" as "and", no leading "the".
create or replace function public.mention_key(p text)
returns text language sql immutable as $$
  select btrim(regexp_replace(
           btrim(regexp_replace(
             regexp_replace(
               replace(translate(lower(coalesce(p, '')), U&'\00E0\00E1\00E2\00E3\00E4\00E5\0101\00E7\0107\010D\00E8\00E9\00EA\00EB\0113\0117\0119\00EC\00ED\00EE\00EF\012B\0142\00F1\0144\00F2\00F3\00F4\00F5\00F6\00F8\014D\015B\0161\00F9\00FA\00FB\00FC\016B\00FD\00FF\017E\017A\017C', 'aaaaaaaccceeeeeeeiiiiilnnooooooossuuuuuyyzzz'),
                       '&', ' and '),
               '[''`.\u2018\u2019]', '', 'g'),
             '[^a-z0-9]+', ' ', 'g')),
           '^the\s+', ''))
$$;

-- A name without what follows a dash, a bar or a comma ("WeWork -
-- Office Space & Coworking" is "WeWork"), as in admin_candidates().
create or replace function public.name_stem(p text)
returns text language sql immutable as $$
  select btrim((regexp_split_to_array(
           regexp_replace(coalesce(p, ''), '[\u200b-\u200d\ufeff]', '', 'g'),
           '\s+[-\u2013\u2014|@]\s+|,\s'))[1])
$$;

-- The sites that were read. weight: 2 a trusted, hand-picked list,
-- 1 an ordinary one, 0 read but not counted.
create table if not exists public.mention_sources (
  source   text primary key,
  url      text,
  kind     text,
  updated  text,
  weight   smallint not null default 1 check (weight between 0 and 3),
  note     text,
  added_at timestamptz not null default now()
);

-- One row for each place a site names in a city.
create table if not exists public.place_mentions (
  city     text not null,
  name_key text not null,
  source   text not null,
  place    text not null,
  kind     text,          -- cafe, coworking
  area     text,          -- the neighbourhood or address the site gives
  url      text,
  seen_on  date not null default current_date,
  primary key (city, name_key, source)
);

-- One row for each named place: which place it turned out to be.
--   waiting    not matched yet
--   listed     a space already on Nomad Maps
--   matched    a found place (a candidate, unless turned down)
--   closed     Google says it has closed
--   not_found  Google has nothing under that name there
--   several    a brand with several places and no branch named
create table if not exists public.mention_places (
  city            text not null,
  name_key        text not null,
  place           text not null,
  status          text not null default 'waiting'
                  check (status in ('waiting', 'listed', 'matched',
                                    'closed', 'not_found', 'several')),
  google_place_id text,
  venue_id        uuid references public.venues(id) on delete set null,
  google_name     text,
  checked_at      timestamptz,
  primary key (city, name_key)
);
create index if not exists idx_mention_places_place
  on public.mention_places (google_place_id);

alter table public.mention_sources enable row level security;
alter table public.place_mentions  enable row level security;
alter table public.mention_places  enable row level security;
drop policy if exists "mention_sources admin" on public.mention_sources;
create policy "mention_sources admin" on public.mention_sources
  for select to authenticated using (public.is_admin());
drop policy if exists "place_mentions admin" on public.place_mentions;
create policy "place_mentions admin" on public.place_mentions
  for select to authenticated using (public.is_admin());
drop policy if exists "mention_places admin" on public.mention_places;
create policy "mention_places admin" on public.mention_places
  for select to authenticated using (public.is_admin());

-- Free matching, before anything is asked of Google: a named place
-- that carries the name of a space on Nomad Maps is "listed"; one that
-- carries the name of exactly one found place around the city is
-- "matched". Returns how many were settled.
create or replace function public.mentions_match_local()
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer := 0;
  m integer := 0;
begin
  if not exists (select 1 from public.mention_places where status = 'waiting') then
    return 0;
  end if;

  -- Each name is worked out once (its own key and its stem's), and
  -- only for the places around a city with names waiting, so the
  -- matching is a join on equal keys and stays quick.
  with centre as (
    select lower(btrim(r.name)) as city, min(r.lat) as lat, min(r.lng) as lng
      from public.webflow_regions r
     where r.lat is not null and r.lng is not null
     group by 1
  ),
  w as (
    select mp.city, mp.name_key, c.lat, c.lng
      from public.mention_places mp
      join centre c on c.city = lower(btrim(mp.city))
     where mp.status = 'waiting'
  ),
  vk as materialized (
    select distinct v.id, v.google_place_id, v.lat, v.lng, v.created_at, t.k
      from public.venues v
     cross join lateral (values (public.mention_key(v.name)),
                                (public.mention_key(public.name_stem(v.name)))) t(k)
     where v.lat is not null and v.lng is not null and t.k <> ''
       and exists (select 1 from w
                    where v.lat between w.lat - 0.5 and w.lat + 0.5
                      and v.lng between w.lng - 0.8 and w.lng + 0.8)
  ),
  hit as (
    select distinct on (w.city, w.name_key)
           w.city, w.name_key, vk.id, vk.google_place_id
      from w
      join vk on vk.k = w.name_key
       and vk.lat between w.lat - 0.5 and w.lat + 0.5
       and vk.lng between w.lng - 0.8 and w.lng + 0.8
     order by w.city, w.name_key, vk.created_at, vk.id
  )
  update public.mention_places mp
     set status = 'listed', venue_id = hit.id,
         google_place_id = hit.google_place_id, checked_at = now()
    from hit
   where mp.city = hit.city and mp.name_key = hit.name_key
     and mp.status = 'waiting';
  get diagnostics n = row_count;

  with centre as (
    select lower(btrim(r.name)) as city, min(r.lat) as lat, min(r.lng) as lng
      from public.webflow_regions r
     where r.lat is not null and r.lng is not null
     group by 1
  ),
  w as (
    select mp.city, mp.name_key, c.lat, c.lng
      from public.mention_places mp
      join centre c on c.city = lower(btrim(mp.city))
     where mp.status = 'waiting'
  ),
  dk as materialized (
    select distinct d.google_place_id, d.name, d.lat, d.lng, t.k
      from public.discovered_places d
     cross join lateral (values (public.mention_key(d.name)),
                                (public.mention_key(public.name_stem(d.name)))) t(k)
     where t.k <> ''
       and exists (select 1 from w
                    where d.lat between w.lat - 0.5 and w.lat + 0.5
                      and d.lng between w.lng - 0.8 and w.lng + 0.8)
       and not exists (select 1 from public.venues v
                        where v.google_place_id = d.google_place_id)
  ),
  hit as (
    select w.city, w.name_key,
           min(dk.google_place_id) as google_place_id, min(dk.name) as name
      from w
      join dk on dk.k = w.name_key
       and dk.lat between w.lat - 0.5 and w.lat + 0.5
       and dk.lng between w.lng - 0.8 and w.lng + 0.8
     group by w.city, w.name_key
    having count(distinct dk.google_place_id) = 1   -- two branches: Google is asked which
  )
  update public.mention_places mp
     set status = 'matched', google_place_id = hit.google_place_id,
         google_name = hit.name, checked_at = now()
    from hit
   where mp.city = hit.city and mp.name_key = hit.name_key
     and mp.status = 'waiting';
  get diagnostics m = row_count;

  return n + m;
end $$;
revoke all on function public.mentions_match_local() from public, anon, authenticated;
grant execute on function public.mentions_match_local() to service_role;

-- A session loads the sites it read:
--   select public.set_mention_sources('[{"source": "Thatsup",
--     "url": "https://...", "kind": "article", "updated": "Aug 2026",
--     "weight": 2}]');
create or replace function public.set_mention_sources(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer := 0;
begin
  insert into public.mention_sources as t (source, url, kind, updated, weight, note)
  select distinct on (btrim(e ->> 'source'))
         btrim(e ->> 'source'),
         nullif(btrim(coalesce(e ->> 'url', '')), ''),
         nullif(btrim(coalesce(e ->> 'kind', '')), ''),
         nullif(left(btrim(coalesce(e ->> 'updated', '')), 80), ''),
         case when (e ->> 'weight') ~ '^[0-3]$' then (e ->> 'weight')::smallint else 1 end,
         nullif(left(btrim(coalesce(e ->> 'note', '')), 300), '')
    from jsonb_array_elements(p) e
   where jsonb_typeof(e) = 'object' and coalesce(btrim(e ->> 'source'), '') <> ''
   order by btrim(e ->> 'source')
  on conflict (source) do update
    set url = excluded.url, kind = excluded.kind, updated = excluded.updated,
        weight = excluded.weight, note = excluded.note;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_mention_sources(jsonb) from public, anon, authenticated;
grant execute on function public.set_mention_sources(jsonb) to service_role;

-- ... and the places they name in one city:
--   select public.set_place_mentions('London', '[{"place": "Prufrock
--     Coffee", "kind": "cafe", "area": "Leather Lane",
--     "source": "Thatsup", "url": "https://..."}]');
-- Adds to what is there. A place named for the first time starts as
-- "waiting"; the free matching runs at once.
create or replace function public.set_place_mentions(p_city text, p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer := 0;
  v_city text := btrim(coalesce(p_city, ''));
begin
  if v_city = '' then
    raise exception 'no city given';
  end if;
  insert into public.place_mentions as t (city, name_key, source, place, kind, area, url)
  select distinct on (x.k, x.source)
         v_city, x.k, x.source, x.place, x.kind, x.area, x.url
    from (select public.mention_key(e ->> 'place') as k,
                 btrim(coalesce(e ->> 'source', '')) as source,
                 left(btrim(regexp_replace(e ->> 'place', '\s+', ' ', 'g')), 200) as place,
                 case when lower(e ->> 'kind') = 'coworking' then 'coworking' else 'cafe' end as kind,
                 nullif(left(btrim(coalesce(e ->> 'area', '')), 200), '') as area,
                 nullif(btrim(coalesce(e ->> 'url', '')), '') as url
            from jsonb_array_elements(p) e
           where jsonb_typeof(e) = 'object') x
   where x.k <> '' and x.source <> ''
   order by x.k, x.source, x.area nulls last
  on conflict (city, name_key, source) do update
    set place = excluded.place, kind = excluded.kind,
        area = coalesce(excluded.area, t.area), url = excluded.url,
        seen_on = current_date;
  get diagnostics n = row_count;

  -- the name as the most trusted of its sites writes it
  insert into public.mention_places (city, name_key, place)
  select distinct on (pm.name_key) pm.city, pm.name_key, pm.place
    from public.place_mentions pm
    left join public.mention_sources ms on ms.source = pm.source
   where pm.city = v_city
   order by pm.name_key, coalesce(ms.weight, 1) desc, length(pm.place), pm.place
  on conflict (city, name_key) do nothing;

  perform public.mentions_match_local();
  return n;
end $$;
revoke all on function public.set_place_mentions(text, jsonb) from public, anon, authenticated;
grant execute on function public.set_place_mentions(text, jsonb) to service_role;

-- The named places to ask Google about, the most named first, each
-- with where to look: the city's centre and the neighbourhood or
-- address most of its sites give. First the ones still waiting; then
-- the ones Google could not place, or said were closed, more than 120
-- days ago (a place reopens, a later reading adds its street).
create or replace function public.mentions_due(p_limit integer default 100)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'city', x.city, 'name_key', x.name_key, 'place', x.place,
           'kind', x.kind, 'area', x.area, 'sources', x.n,
           'lat', x.lat, 'lng', x.lng) order by x.rn), '[]'::jsonb)
    from (select mp.city, mp.name_key, mp.place, c.lat, c.lng,
                 a.n, a.area, a.kind,
                 row_number() over (order by (mp.status = 'waiting') desc,
                                             a.points desc, a.n desc,
                                             mp.city, mp.name_key) as rn
            from public.mention_places mp
            join (select lower(btrim(r.name)) as city,
                         min(r.lat) as lat, min(r.lng) as lng
                    from public.webflow_regions r
                   where r.lat is not null and r.lng is not null
                   group by 1) c on c.city = lower(btrim(mp.city))
            join lateral (
              select count(*)::integer as n,
                     coalesce(sum(coalesce(ms.weight, 1)), 0)::integer as points,
                     -- "various locations" is no place to look
                     mode() within group (order by pm.area)
                       filter (where pm.area is not null
                                 and pm.area !~* 'various|multiple|several|locations|branches|sites|across|citywide')
                       as area,
                     case when bool_or(pm.kind = 'coworking')
                          then 'coworking' else 'cafe' end as kind
                from public.place_mentions pm
                left join public.mention_sources ms on ms.source = pm.source
               where pm.city = mp.city and pm.name_key = mp.name_key) a on true
           where a.points > 0
             -- quality before quantity: only a name its sites make
             -- worth a call (the settings above)
             and a.points >= (public.evidence_plan() ->> 'min_points')::integer
             and (public.evidence_plan() -> 'cities') ? lower(btrim(mp.city))
             and (mp.status = 'waiting'
                  or (mp.status in ('not_found', 'several', 'closed')
                      and mp.checked_at < now() - interval '120 days'))) x
   where x.rn <= greatest(0, least(coalesce(p_limit, 100), 500))
$$;
revoke all on function public.mentions_due(integer) from public, anon, authenticated;
grant execute on function public.mentions_due(integer) to service_role;

-- The nightly job writes what Google said about each. Each row:
-- {"city", "name_key", "kind", "status": "matched" | "closed" |
--  "not_found" | "several", "google_place_id", "google_name",
--  "row": {"name", "lat", "lng", "primary_type", "rating",
--          "user_rating_count", "address"}}.
-- A match that is a space on Nomad Maps becomes "listed"; any other
-- match is kept as a found place, so it can be a candidate. A place
-- new to us that a coworking list names is kept as a coworking space,
-- whatever Google files it under (the map draws found places by it).
create or replace function public.record_mention_checks(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  e        jsonb;
  r        jsonb;
  v_status text;
  v_gid    text;
  v_venue  uuid;
  n        integer := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    return 0;
  end if;
  for e in select * from jsonb_array_elements(p) loop
    continue when jsonb_typeof(e) <> 'object';
    v_status := lower(btrim(coalesce(e ->> 'status', '')));
    continue when v_status not in ('matched', 'closed', 'not_found', 'several');
    v_gid := nullif(btrim(coalesce(e ->> 'google_place_id', '')), '');
    v_venue := null;
    r := e -> 'row';
    if v_status = 'matched' then
      if v_gid is null then
        v_status := 'not_found';
      else
        select v.id into v_venue from public.venues v
         where v.google_place_id = v_gid order by v.created_at limit 1;
        if v_venue is not null then
          v_status := 'listed';
        elsif jsonb_typeof(r) = 'object'
              and (r ->> 'lat') ~ '^-?[0-9]{1,3}(\.[0-9]+)?$'
              and (r ->> 'lng') ~ '^-?[0-9]{1,3}(\.[0-9]+)?$' then
          insert into public.discovered_places as d
            (google_place_id, name, lat, lng, primary_type, rating,
             user_rating_count, address)
          values (
            v_gid,
            left(coalesce(nullif(btrim(r ->> 'name'), ''), 'Unnamed'), 300),
            (r ->> 'lat')::double precision,
            (r ->> 'lng')::double precision,
            case when lower(e ->> 'kind') = 'coworking' then 'coworking_space'
                 else nullif(btrim(coalesce(r ->> 'primary_type', '')), '') end,
            case when (r ->> 'rating') ~ '^[0-9](\.[0-9]+)?$'
                 then (r ->> 'rating')::numeric end,
            case when (r ->> 'user_rating_count') ~ '^[0-9]{1,9}$'
                 then (r ->> 'user_rating_count')::integer end,
            nullif(left(btrim(coalesce(r ->> 'address', '')), 200), ''))
          on conflict (google_place_id) do update
            set address = coalesce(nullif(btrim(d.address), ''), excluded.address);
        elsif not exists (select 1 from public.discovered_places d
                           where d.google_place_id = v_gid) then
          v_status := 'not_found';
        end if;
      end if;
    end if;
    update public.mention_places mp
       set status = v_status, google_place_id = v_gid, venue_id = v_venue,
           google_name = nullif(left(btrim(coalesce(e ->> 'google_name', '')), 200), ''),
           checked_at = now()
     where mp.city = e ->> 'city' and mp.name_key = e ->> 'name_key';
    if found then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.record_mention_checks(jsonb) from public, anon, authenticated;
grant execute on function public.record_mention_checks(jsonb) to service_role;

-- ------------------------------------- 3. Candidates, with both signs

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

  with mention_agg as (
    -- Who names each place: one count per site, however many of its
    -- pages or spellings name it. Weak sources (weight 0) are out.
    select x.google_place_id,
           count(*)::integer      as n,
           sum(x.weight)::integer as points,
           (array_agg(x.source order by x.weight desc, x.source))[1:4] as names,
           bool_or(x.cowork)      as cowork
      from (select mp.google_place_id, pm.source,
                   max(coalesce(ms.weight, 1)) as weight,
                   bool_or(pm.kind = 'coworking') as cowork
              from public.mention_places mp
              join public.place_mentions pm
                on pm.city = mp.city and pm.name_key = mp.name_key
              left join public.mention_sources ms on ms.source = pm.source
             where mp.status = 'matched' and mp.google_place_id is not null
               and coalesce(ms.weight, 1) > 0
             group by mp.google_place_id, pm.source) x
     group by x.google_place_id
  ),
  open_places as (
    select d.google_place_id, d.name, d.lat, d.lng, d.primary_type,
           d.rating, d.user_rating_count, d.signals_checked_at,
           d.fetched_at,
           nullif(btrim(coalesce(d.address, '')), '') as address,
           -- the name without what follows a dash, a bar or a comma
           -- ("WeWork - Office Space & Coworking" is "wework"), to see
           -- which places carry one brand's name
           lower(btrim((regexp_split_to_array(
             regexp_replace(d.name, '[\u200b-\u200d\ufeff]', '', 'g'),
             '\s+[-\u2013\u2014|@]\s+|,\s'))[1])) as stem,
           coalesce(d.signal_wifi, 0)     as wifi,
           coalesce(d.signal_power, 0)    as power,
           coalesce(d.signal_laptop, 0)   as laptop,
           coalesce(d.signal_negative, 0) as negative,
           coalesce(d.signal_food, 0)     as food,
           coalesce(d.work_phrases, '{}'::text[]) as work_phrases,
           coalesce(array_length(d.work_phrases, 1), 0) as work_hits,
           coalesce(ma.n, 0)      as mention_n,
           coalesce(ma.points, 0) as mention_points,
           coalesce(ma.names, '{}'::text[]) as mention_names,
           (coalesce(d.primary_type, '') = 'coworking_space'
            or d.name ~* 'cowork|co-work|co work|workspace|work ?space|work ?hub|wework'
            -- a coworking list names it: a coworking space, whatever
            -- Google files it under
            or coalesce(ma.cowork, false))
             as coworking
      from public.discovered_places d
      left join mention_agg ma on ma.google_place_id = d.google_place_id
     -- Google told us it has closed (asked about a place another
     -- site names): never a candidate, whatever its reviews said
     where not exists (select 1 from public.mention_places mc
                        where mc.google_place_id = d.google_place_id
                          and mc.status = 'closed')
       and not exists (select 1 from public.venues v
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
                  else 0 end
           -- Google's own search returns it for a place to work, and
           -- other sites name it (a trusted one counts double)
           + 4 * least(o.work_hits, 2)
           + 3 * least(o.mention_points, 6) as score
      from open_places o
     where o.negative = 0
       and (o.wifi > 0 or o.power > 0 or o.laptop > 0 or o.coworking
            or o.work_hits > 0 or o.mention_n > 0)
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
  -- A phrase given to several places ("wework london" to four
  -- WeWorks) is the brand's, not one branch's: counted across every
  -- place it was given to, also the ones decided since.
  phrase_shared as (
    select c.phrase, count(*)::integer as n
      from public.candidate_search c
     where btrim(coalesce(c.phrase, '')) <> ''
     group by c.phrase
  ),
  -- How many places Google shows around it under the same name, read
  -- or not, worth a page or not: one Starbucks among six in a city is
  -- a chain's branch.
  named as (
    select w.google_place_id, count(*)::integer as n
      from worthy w
      join open_places o
        on o.stem = w.stem
       and o.lat between w.lat - 0.3 and w.lat + 0.3
       and o.lng between w.lng - 0.6 and w.lng + 0.6
     where length(w.stem) > 0
     group by w.google_place_id
  ),
  scored as (
    select l.*,
           coalesce(nm.n, 1) as same_name,
           -- how many places share its searches: every place its
           -- phrase was given to, and for a name that only counts
           -- with its city ("starbucks porto"), every place around
           -- with that name
           greatest(coalesce(ps.n, 1),
                    case when cs.confidence = 'city' then coalesce(nm.n, 1) else 1 end)
             as brand_n,
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
      left join phrase_shared ps on ps.phrase = cs.phrase
      left join named nm on nm.google_place_id = l.google_place_id
      left join public.region_search rs on rs.region = lower(btrim(l.area))
      left join listed li on li.region = lower(btrim(l.area))
  ),
  shared as (
    -- this place's share of its name's searches: all of them, or one
    -- part when the name is a brand's with several places
    select s.*,
           case when s.brand_n > 1 then round(s.searches::numeric / s.brand_n)::integer
                else s.searches end as own_searches
      from scored s
  ),
  pointed as (
    select s.*,
           case when not s.looked_up
                  or s.search_confidence in ('general', 'none')
                  or s.other_type then 0
                else case when s.own_searches >= 1000 then 6
                          when s.own_searches >= 500  then 5
                          when s.own_searches >= 200  then 4
                          when s.own_searches >= 100  then 3
                          when s.own_searches >= 30   then 2
                          when s.own_searches >= 10   then 1
                          else 0 end
           end as name_points,
           case when s.coworking and s.city_searches >= 300 and s.city_listed < 8
                then case when s.city_searches >= 1000 then 5 else 3 end
                else 0 end as gap_points,
           -- what "most searched" counts: a number that means the place
           case when s.looked_up and s.search_confidence in ('sure', 'city', 'unsure')
                then s.own_searches end as counted
      from shared s
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
               'address', g.address,
               'same_name', g.same_name,
               'mentions', g.mention_n,
               'mention_sources', to_jsonb(g.mention_names),
               'work_phrases', to_jsonb(g.work_phrases),
               'search_shared', g.brand_n,
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
                      where o.signals_checked_at is null and not o.coworking
                        -- already on the list on other signs
                        and o.work_hits = 0 and o.mention_n = 0),
    'dismissed', (select count(*) from public.candidate_decisions c
                   where c.decision = 'dismissed'),
    -- the day most of the search numbers are from, and how many
    -- places on the list were found after a lookup and have none
    'search_measured', (select mode() within group (order by cs.measured_on)
                          from public.candidate_search cs),
    'without_search', (select count(*) from placed p where not p.looked_up),
    -- What the other sites and blogs name (the chosen city, or all):
    -- how many sites were read, how many places they name, and where
    -- each of those stands.
    'mention_summary', (
      select jsonb_build_object(
               'sources', (select count(distinct pm.source)
                             from public.place_mentions pm
                            where p_area is null or lower(pm.city) = lower(p_area)),
               'places',    count(*),
               -- a match queued since is a space now, not a candidate
               'listed',    count(*) filter (where mp.status = 'listed' or lv.id is not null),
               'on_site',   count(*) filter (
                              where (mp.status = 'listed'
                                     and exists (select 1 from public.venues v
                                                  where v.id = mp.venue_id
                                                    and v.website_status = 'released'))
                                 or lv.website_status = 'released'),
               'matched',   count(*) filter (where mp.status = 'matched' and lv.id is null),
               'closed',    count(*) filter (where mp.status = 'closed'),
               'not_found', count(*) filter (where mp.status = 'not_found'),
               'several',   count(*) filter (where mp.status = 'several'),
               'waiting',   count(*) filter (where mp.status = 'waiting' and mq.points >= mq.bar),
               -- named by too little to be worth a call for now
               'parked',    count(*) filter (where mp.status = 'waiting' and mq.points < mq.bar))
        from public.mention_places mp
        left join lateral (
          select v.id, v.website_status from public.venues v
           where mp.status = 'matched' and v.google_place_id = mp.google_place_id
           order by v.created_at limit 1) lv on true
        left join lateral (
          select coalesce(sum(coalesce(ms.weight, 1)), 0)::integer as points,
                 (public.evidence_plan() ->> 'min_points')::integer as bar
            from public.place_mentions pm
            left join public.mention_sources ms on ms.source = pm.source
           where pm.city = mp.city and pm.name_key = mp.name_key) mq on true
       where p_area is null or lower(mp.city) = lower(p_area)),
    -- what may be asked of Google for this, and what has been
    'evidence_plan', public.evidence_plan()
  ) into out;

  return out;
end $$;
revoke all on function public.admin_candidates(text, integer, integer, text)
  from public, anon;
grant execute on function public.admin_candidates(text, integer, integer, text)
  to authenticated;
