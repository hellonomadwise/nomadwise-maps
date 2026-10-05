-- ============================================================
-- Migration 139: a brand's searches are not one branch's, and each
-- candidate says where it is.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026: four cards read "WeWork - Office Space &
-- Coworking, London" with "About 2,300 searches a month for wework
-- london" on each, at the top of "most searched first". Too generic:
-- nothing told the four apart, and the 2,300 are searches for WeWork
-- in London, not for any one of them.
--
-- What this changes:
--   discovered_places.address  the short address Google gives ("8
--                              Devonshire Square, London"), filled by
--                              the nightly job (scripts/
--                              enrich_venues.py): with the reviews for
--                              a place read from now on, and in a
--                              catch-up of its own for the places
--                              already read.
--   admin_candidates()         each row also carries its address, how
--                              many places Google shows around it
--                              under the same name (same_name) and
--                              how many places share its searches
--                              (search_shared): the places its phrase
--                              was given to, and for a name that only
--                              counts with its city ("starbucks
--                              porto") every place around with that
--                              name. Shared searches are the brand's:
--                              each place is ordered on its share
--                              (2,300 across four is 575 each), in
--                              both orders.
--
-- Nothing here writes to a candidate, a space or the website.
-- ============================================================

alter table public.discovered_places
  add column if not exists address text;

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
