-- Migration 155: a Location only when it is almost certain, and a map
-- of the spaces nearby to decide by.
--
-- Jonathan, 6 and 7 Oct 2026, on the review card of a space about to
-- get a page: "I want to make a system on how to assign a location...
-- it should consider the existing locations within nomadwise, and go
-- about a systematic way of assigning a new one, but only if it's
-- almost certain. It should be something that most people would
-- consider it to be. It also varies depending on whether it's a
-- city, or island, or rural location." And: "I would like to see
-- potential other spaces nearby on a map, because if a previous space
-- has been assigned a location, it makes it easier to decide if the
-- new space should also have that location (but not always)." His
-- words for the three levels: Country, Region, Location.
--
-- Until now the website sync gave a space the first Location whose
-- name matched any of its area names, anywhere in the world (so Kuta
-- on Lombok could be filed under Kuta on Bali), and called it a guess.
-- From here:
--   * Two signs are read. A: one of the names of the space's area is
--     a Location of its own Region. B: the nearest listed places of
--     that Region agree on a Location (at least two of them, and two
--     in three).
--   * Both, and the same Location: it is assigned. One of them, or
--     two that disagree: it is a suggestion on the card, his to take
--     with one tap. Neither: no Location, which is fine.
--   * How far "nearest" reaches depends on the kind of Region: a
--     city (1.5 km), an island (4 km), a rural or wide area (8 km).
--     The kind is seeded here by name and can be changed in the app.
--   * The map: every listed place around the space, with its
--     Location, for the app to draw.
-- The sync keeps each listed place's Region and Location (their
-- Webflow ids) on the venue from its next nightly run; until then
-- they are filled in here from the Location's name and the nearest
-- Region, which is close but not exact. It also keeps the names
-- Google gives a space's area (g_area), so Google is asked once per
-- space and not on every run.
-- Not here yet: proposing a new Location once five places share an
-- area name. The area names have to be collected first.

alter table public.venues
  add column if not exists webflow_region_id text,
  add column if not exists webflow_location_id text,
  add column if not exists g_area jsonb;
create index if not exists idx_venues_webflow_region
  on public.venues (webflow_region_id) where webflow_region_id is not null;
create index if not exists idx_venues_webflow_location
  on public.venues (webflow_location_id) where webflow_location_id is not null;

alter table public.webflow_regions
  add column if not exists kind text;
do $$
begin
  alter table public.webflow_regions
    add constraint webflow_regions_kind_check
    check (kind in ('city', 'island', 'rural'));
exception when duplicate_object then
  null;
end $$;

-- The kind of each Region, where it is not a city. A first sorting
-- by name; "Region kind" on the map in the app changes it.
update public.webflow_regions r
   set kind = 'island'
 where r.kind is null
   and (lower(btrim(r.name)) in (
          'bali', 'lombok', 'gili islands', 'nusa penida', 'koh lanta',
          'koh phangan', 'koh samui', 'koh tao', 'phuket island', 'penang',
          'cebu', 'siargao', 'crete', 'rhodes', 'ibiza', 'mallorca',
          'gran canaria', 'madeira', 'boa vista', 'sal', 'sao vicente')
        or (lower(btrim(r.name)) = 'santiago'
            and lower(btrim(coalesce(r.country, ''))) = 'cape verde'));
update public.webflow_regions r
   set kind = 'rural'
 where r.kind is null
   and lower(btrim(r.name)) in (
          'east java', 'surat thani', 'hochtaunuskreis', 'paphos', 'el nido');

-- Kilometres between two points.
create or replace function public.km_between(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 6371 * 2 * asin(least(1, sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2)
           + cos(radians(lat1)) * cos(radians(lat2))
             * power(sin(radians(lng2 - lng1) / 2), 2))));
$$;

-- An area's name as letters and digits only, accents off, so "Sao
-- Bento" and the same with its tilde are one name. (The accented
-- letters are written as codes so this file stays in plain
-- characters.)
create or replace function public.area_key(p text)
returns text language sql immutable as $$
  select regexp_replace(translate(lower(coalesce(p, '')),
    U&'\00e1\00c1\00e0\00c0\00e2\00c2\00e4\00c4\00e3\00c3\00e5\00c5\0101\0100\0103\0102\0105\0104\00e7\00c7\0107\0106\010d\010c\010f\010e\0111\0110\00e9\00c9\00e8\00c8\00ea\00ca\00eb\00cb\0113\0112\0117\0116\0119\0118\011b\011a\011f\011e\00ed\00cd\00ec\00cc\00ee\00ce\00ef\00cf\012b\012a\0131\0049\0142\0141\00f1\00d1\0144\0143\0148\0147\00f3\00d3\00f2\00d2\00f4\00d4\00f6\00d6\00f5\00d5\00f8\00d8\014d\014c\0151\0150\0159\0158\015b\015a\0161\0160\015f\015e\0165\0164\0163\0162\00fa\00da\00f9\00d9\00fb\00db\00fc\00dc\016b\016a\016f\016e\0171\0170\00fd\00dd\00ff\0178\017e\017d\017a\0179\017c\017b',
    'aaaaaaaaaaaaaaaaaaccccccddddeeeeeeeeeeeeeeeeggiiiiiiiiiiiillnnnnnnoooooooooooooooorrssssssttttuuuuuuuuuuuuuuyyyyzzzzzz'), '[^a-z0-9]+', '', 'g');
$$;

-- Until the sync's next nightly run: each listed place's Location from
-- its name (the nearest Region that has a Location of that name,
-- within 100 km), and its Region from that, or else the nearest
-- Region within 40 km.
update public.venues v
   set webflow_location_id = h.id,
       webflow_region_id = h.region_id
  from (
    select distinct on (x.id) x.id as venue_id, l.id, l.region_id
      from public.venues x
      join public.webflow_locations l
        on public.area_key(l.name) = public.area_key(x.neighbourhood)
      join public.webflow_regions r on r.id = l.region_id
     where x.webflow_cms_id is not null
       and x.webflow_location_id is null
       and x.webflow_region_id is null
       and public.area_key(x.neighbourhood) <> ''
       and x.lat is not null and x.lng is not null
       and r.lat is not null and r.lng is not null
       and public.km_between(x.lat, x.lng, r.lat, r.lng) <= 100
     order by x.id, public.km_between(x.lat, x.lng, r.lat, r.lng)
  ) h
 where v.id = h.venue_id;

update public.venues v
   set webflow_region_id = h.region_id
  from (
    select distinct on (x.id) x.id as venue_id, r.id as region_id
      from public.venues x
      join public.webflow_regions r
        on r.lat is not null and r.lng is not null
       and r.lat between x.lat - 0.5 and x.lat + 0.5
     where x.webflow_cms_id is not null
       and x.webflow_region_id is null
       and x.lat is not null and x.lng is not null
       and public.km_between(x.lat, x.lng, r.lat, r.lng) <= 40
     order by x.id, public.km_between(x.lat, x.lng, r.lat, r.lng)
  ) h
 where v.id = h.venue_id;

-- ------------------------------------------------ the verdict
-- For a space, the Region it is in, and the names of its area (most
-- exact first): which Location, how sure, and why, in a sentence.
--   verdict 'assign'   both signs, the same Location
--           'suggest'  one sign, or two that disagree (the name's
--                      Location is the suggestion, the other is "alt")
--           'none'     no sign
create or replace function public.location_verdict(
  p_venue uuid, p_region text, p_names text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v       record;
  r       record;
  radius  double precision;
  a_id    text;
  a_name  text;
  b_id    text;
  b_name  text;
  b_n     integer := 0;
  b_of    integer := 0;
  b_says  boolean := false;
  verdict text := 'none';
  loc_id  text;
  loc     text;
  alt     jsonb;
  why     text;
  b_words text;
  b_none  text;
begin
  select x.id, x.name, x.lat, x.lng into v
    from public.venues x where x.id = p_venue;
  select g.id, g.name, coalesce(g.kind, 'city') as kind into r
    from public.webflow_regions g where g.id = p_region;
  if v.id is null or r.id is null then
    return jsonb_build_object('verdict', 'none');
  end if;
  radius := case r.kind when 'island' then 4 when 'rural' then 8 else 1.5 end;

  -- A: the first of the area's names that is a Location of this Region.
  -- (A Location the site has dropped stops being copied here, and
  -- stops counting three days later.)
  select l.id, coalesce(nullif(btrim(l.name), ''), 'a Location') into a_id, a_name
    from unnest(coalesce(p_names, '{}'::text[])) with ordinality as n(name, ord)
    join public.webflow_locations l
      on l.region_id = p_region
     and public.area_key(l.name) = public.area_key(n.name)
   where public.area_key(n.name) <> ''
     and l.updated_at > now() - interval '3 days'
   order by n.ord, l.id
   limit 1;

  -- B: the six nearest listed places of this Region that have one of
  -- its Locations, within reach. (A listed place with no Location
  -- says nothing either way and is not counted.)
  if v.lat is not null and v.lng is not null then
    with near as (
      select x.webflow_location_id as lid,
             public.km_between(v.lat, v.lng, x.lat, x.lng) as km
        from public.venues x
        join public.webflow_locations wl
          on wl.id = x.webflow_location_id and wl.region_id = p_region
         and wl.updated_at > now() - interval '3 days'
       where x.id <> p_venue
         and x.webflow_cms_id is not null
         and x.website_status = 'released'
         and x.webflow_region_id = p_region
         and x.webflow_location_id is not null
         and x.lat is not null and x.lng is not null
         and coalesce(x.business_status, '') <> 'CLOSED_PERMANENTLY'
         and public.km_between(v.lat, v.lng, x.lat, x.lng) <= radius
       order by 2
       limit 6
    )
    select (select count(*) from near)::integer, g.lid, g.n
      into b_of, b_id, b_n
      from (select near.lid, count(*)::integer as n, min(near.km) as nearest
              from near group by near.lid
             order by count(*) desc, min(near.km)
             limit 1) g;
    b_of := coalesce(b_of, 0);
    b_n := coalesce(b_n, 0);
    if b_id is not null then
      select l.name into b_name from public.webflow_locations l where l.id = b_id;
      b_name := coalesce(nullif(btrim(b_name), ''), 'a Location');
    end if;
    b_says := b_of >= 2 and b_n >= 2 and b_n * 3 >= b_of * 2;
  end if;
  -- "both", "all 3", "3 of the 4": how many of the nearest agree
  b_words := case when b_n = b_of and b_of = 2
                  then 'both of the nearest listed places with a Location are in '
                  when b_n = b_of
                  then 'all ' || b_of || ' of the nearest listed places with a Location are in '
                  else b_n || ' of the ' || b_of
                       || ' nearest listed places with a Location are in ' end;
  -- what to say when the places nearby do not settle it
  b_none := case when v.lat is null or v.lng is null
                 then 'The space has no position on the map, so the places nearby cannot be compared.'
                 when b_of = 0 then 'No listed place with a Location is near enough to compare.'
                 when b_of = 1 then 'Only one listed place with a Location is near, which is not enough to go by.'
                 else 'The ' || b_of || ' nearest listed places with a Location do not agree on one.' end;

  if a_id is not null and b_says and a_id = b_id then
    verdict := 'assign'; loc_id := a_id; loc := a_name;
    why := 'The area is called ' || a_name || ', and ' || b_words || b_name || ' too.';
  elsif a_id is not null and b_says then
    verdict := 'suggest'; loc_id := a_id; loc := a_name;
    alt := jsonb_build_object('id', b_id, 'name', b_name);
    why := 'The area is called ' || a_name || ', but ' || b_words || b_name
           || '. Look at the map before choosing.';
  elsif a_id is not null then
    verdict := 'suggest'; loc_id := a_id; loc := a_name;
    why := 'The area is called ' || a_name || ', which is a Location in '
           || r.name || '. ' || b_none;
  elsif b_says then
    verdict := 'suggest'; loc_id := b_id; loc := b_name;
    why := upper(left(b_words, 1)) || substr(b_words, 2) || b_name
           || '. None of the area''s own names is a Location in ' || r.name || '.';
  else
    why := 'Nothing points to a Location. None of the area''s names is one in '
           || r.name || '. ' || b_none;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'verdict', verdict,
    'location_id', loc_id,
    'location', loc,
    'why', why,
    'alt', alt,
    'name_says', case when a_id is not null
                      then jsonb_build_object('id', a_id, 'name', a_name) end,
    'nearby_says', case when b_id is not null
                        then jsonb_build_object('id', b_id, 'name', b_name,
                                                'n', b_n, 'of', b_of, 'agree', b_says) end,
    'region_id', r.id, 'region', r.name, 'kind', r.kind, 'radius_km', radius));
end $$;
revoke all on function public.location_verdict(uuid, text, text[]) from public, anon, authenticated;
grant execute on function public.location_verdict(uuid, text, text[]) to service_role;

-- ------------------------------------------------ for the app: the verdict and the map
-- Everything the review card's map needs for one space: the space,
-- its Region and that Region's kind, the verdict above, the listed
-- places around it with their Locations, and the Region's Locations.
-- A space with no Region yet gets the places around it of any Region,
-- which helps to pick one. The app may pass the Region it shows for a
-- space the sync has not prepared yet, and the area names it holds.
create or replace function public.admin_location_help(
  p_venue uuid, p_region text default null, p_names text[] default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v      record;
  rid    text;
  r      record;
  names  text[];
  reach  double precision;
  spots  jsonb;
  locs   jsonb;
  verdict jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select x.id, x.name, x.type, x.lat, x.lng, x.city, x.neighbourhood, x.g_area,
         x.website_region_override, x.website_location_override,
         x.website_prepared, x.webflow_region_id, x.webflow_cms_id
    into v
    from public.venues x where x.id = p_venue;
  if v.id is null then
    raise exception 'No such space.';
  end if;

  -- Its Region, the first of these that the site has: the founder's
  -- choice (an id, or a name from before); for a place that already
  -- has a page, the page's own; what the sync prepared; what the app
  -- shows; the page's own.
  rid := nullif(btrim(coalesce(v.website_region_override, '')), '');
  if rid is not null and not exists (select 1 from public.webflow_regions g where g.id = rid) then
    select g.id into rid from public.webflow_regions g
     where lower(btrim(g.name)) = lower(rid) limit 1;
  end if;
  select c.id into rid
    from unnest(array[
           rid,
           case when v.webflow_cms_id is not null then v.webflow_region_id end,
           nullif(v.website_prepared ->> 'region_id', ''),
           nullif(btrim(coalesce(p_region, '')), ''),
           v.webflow_region_id]) with ordinality as c(id, o)
   where c.id is not null
     and exists (select 1 from public.webflow_regions g where g.id = c.id)
   order by c.o
   limit 1;
  select g.id, g.name, g.country, coalesce(g.kind, 'city') as kind, g.lat, g.lng into r
    from public.webflow_regions g where g.id = rid;

  names := array[v.neighbourhood, v.city]::text[]
           || coalesce((select array_agg(e ->> 'n' order by o)
                          from jsonb_array_elements(
                                 case when jsonb_typeof(v.g_area) = 'array'
                                      then v.g_area else '[]'::jsonb end)
                               with ordinality as a(e, o)), '{}'::text[])
           || coalesce(p_names[1:12], '{}'::text[]);
  -- most exact first: the neighbourhood, Google's names, then the town
  names := names[1:1] || names[3:] || names[2:2];
  names := array(select n from unnest(names) with ordinality as t(n, o)
                  where btrim(coalesce(n, '')) <> '' order by o);

  if r.id is not null then
    verdict := public.location_verdict(p_venue, r.id, names);
    reach := greatest(6, 4 * (verdict ->> 'radius_km')::double precision);
  else
    verdict := jsonb_build_object('verdict', 'none',
                 'why', 'This space has no Region yet. Pick one first: the places around it are shown with theirs.');
    reach := 15;
  end if;

  if v.lat is not null and v.lng is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', s.id, 'name', s.name, 'type', s.type,
             'lat', s.lat, 'lng', s.lng, 'km', round(s.km::numeric, 2),
             'region_id', s.webflow_region_id, 'region', s.region,
             'location_id', s.webflow_location_id, 'location', s.location)
             order by s.km), '[]'::jsonb)
      into spots
      from (select x.id, x.name, x.type, x.lat, x.lng,
                   x.webflow_region_id, x.webflow_location_id,
                   public.km_between(v.lat, v.lng, x.lat, x.lng) as km,
                   g.name as region,
                   l.name as location
              from public.venues x
              left join public.webflow_regions g on g.id = x.webflow_region_id
              left join public.webflow_locations l on l.id = x.webflow_location_id
             where x.id <> p_venue
               and x.webflow_cms_id is not null
               and x.website_status = 'released'
               and x.lat is not null and x.lng is not null
               and coalesce(x.business_status, '') <> 'CLOSED_PERMANENTLY'
               and (r.id is null or x.webflow_region_id = r.id
                    or x.webflow_region_id is null)
               and x.lat between v.lat - 0.3 and v.lat + 0.3
               and public.km_between(v.lat, v.lng, x.lat, x.lng) <= reach
             order by 8
             limit 200) s;
  end if;

  if r.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', l.id, 'name', l.name,
             'places', (select count(*) from public.venues x
                         where x.webflow_location_id = l.id
                           and x.webflow_cms_id is not null
                           and x.website_status = 'released'))
             order by l.name), '[]'::jsonb)
      into locs
      from public.webflow_locations l
     where l.region_id = r.id
       and l.updated_at > now() - interval '3 days';
  end if;

  return jsonb_build_object(
    'venue', jsonb_build_object('id', v.id, 'name', v.name, 'type', v.type,
                                'lat', v.lat, 'lng', v.lng,
                                'location_override', v.website_location_override),
    'region', case when r.id is not null then jsonb_build_object(
                'id', r.id, 'name', r.name, 'country', r.country, 'kind', r.kind) end,
    'area_names', to_jsonb(names),
    'verdict', verdict,
    'reach_km', reach,
    'spots', coalesce(spots, '[]'::jsonb),
    'locations', coalesce(locs, '[]'::jsonb));
end $$;
revoke all on function public.admin_location_help(uuid, text, text[]) from public, anon;
grant execute on function public.admin_location_help(uuid, text, text[]) to authenticated;

-- What kind of Region this is: a city, an island, or a rural or wide
-- area. It sets how far the nearest listed places are looked for.
create or replace function public.admin_set_region_kind(p_region text, p_kind text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if p_kind not in ('city', 'island', 'rural') then
    raise exception 'A Region is a city, an island, or a rural or wide area.';
  end if;
  update public.webflow_regions set kind = p_kind where id = p_region;
  if not found then
    raise exception 'No such Region.';
  end if;
end $$;
revoke all on function public.admin_set_region_kind(text, text) from public, anon;
grant execute on function public.admin_set_region_kind(text, text) to authenticated;
