-- ============================================================
-- Migration 129: Candidates, the link between the map's promising
-- places and the control centre.
-- (Applied automatically by the build; nothing to paste.)
--
-- Until now a place the nightly job found and marked promising only
-- reached the control centre after someone reviewed it in the app.
-- Nothing showed the founders the promising ones as a list to decide
-- on. This adds that list.
--
-- A candidate is a discovered place that is not a space yet, has not
-- been turned down, and is worth a look:
--   * its Google reviews mention wifi, plugs or laptops and none of
--     them warn against working there (the map's "promising" rule), or
--   * it is a coworking space (a place to work by definition).
--
-- Two decisions, both founders only:
--   Queue for the site -> the place becomes a space, already queued,
--                         and follows the pipeline that exists: a
--                         proposal, then Approve, then the Webflow
--                         draft. Nothing reaches Webflow without the
--                         Approve that was always needed.
--   Not for the site   -> kept here with its reason, off the list,
--                         with a way back.
--
-- Nothing in this file changes an existing table, row or function.
-- ============================================================

-- 1. What the founders decided about a discovered place. Kept apart
--    from discovered_places because anyone may write to that cache;
--    only founders may read or write this.
create table if not exists public.candidate_decisions (
  google_place_id text primary key,
  decision        text not null check (decision in ('dismissed', 'queued')),
  name            text,
  reason          text,
  note            text,
  venue_id        uuid references public.venues(id) on delete set null,
  decided_by      uuid references auth.users(id),
  decided_at      timestamptz not null default now()
);

alter table public.candidate_decisions enable row level security;

drop policy if exists "admin manages candidate decisions"
  on public.candidate_decisions;
create policy "admin manages candidate decisions"
  on public.candidate_decisions
  for all using (public.is_admin()) with check (public.is_admin());

-- 2. The Region (city page) a point belongs to: the nearest one within
--    30 km, the same reach migration 119 uses for the country. Null
--    when the site has no city page that close.
create or replace function public.candidate_region(p_lat double precision,
                                                   p_lng double precision)
returns table (region_id text, region_name text, region_country text)
language sql stable security definer set search_path = public as $$
  select r.id, r.name, nullif(trim(r.country), '')
    from public.webflow_regions r
   where r.lat is not null and r.lng is not null
     and p_lat is not null and p_lng is not null
     -- a cheap box first, so the distance is worked out for few rows
     and r.lat between p_lat - 0.3 and p_lat + 0.3
     and r.lng between p_lng - 1.0 and p_lng + 1.0
     and 6371 * 2 * asin(sqrt(least(1,
           power(sin(radians(r.lat - p_lat) / 2), 2)
           + cos(radians(p_lat)) * cos(radians(r.lat))
           * power(sin(radians(r.lng - p_lng) / 2), 2)))) <= 30
   order by power(r.lat - p_lat, 2)
          + power((r.lng - p_lng) * cos(radians(p_lat)), 2)
   limit 1
$$;
revoke all on function public.candidate_region(double precision, double precision)
  from public, anon;
grant execute on function public.candidate_region(double precision, double precision)
  to authenticated, service_role;

-- 3. The list. One call returns the page of cards for the chosen
--    area, the count per area for the picker, and the totals for the
--    line above the list.
--
--    Order: strongest evidence first. Laptop mentions weigh most (a
--    reviewer worked there), then plugs and wifi, a coworking space
--    gets a head start, and a well-reviewed place edges out a thinly
--    reviewed one. Google's feed carries five reviews per place, so
--    each count runs from 0 to 5.
create or replace function public.admin_candidates(
  p_area   text default null,
  p_limit  integer default 60,
  p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  out jsonb;
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
  placed as (
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
  page as (
    select *
      from placed p
     where p_area is null or p.area = p_area
     order by p.score desc, p.user_rating_count desc nulls last, p.name
     limit greatest(1, least(coalesce(p_limit, 60), 200))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select jsonb_build_object(
    'total', (select count(*) from placed),
    'shown_total', (select count(*) from placed p
                     where p_area is null or p.area = p_area),
    'areas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'area', a.area, 'n', a.n, 'has_page', a.has_page)
               order by a.n desc, a.area)
        from (select p.area, count(*) as n,
                     bool_or(p.region_id is not null) as has_page
                from placed p group by p.area) a), '[]'::jsonb),
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
               'region_country', g.region_country)
               order by g.score desc, g.user_rating_count desc nulls last, g.name)
        from page g), '[]'::jsonb),
    -- found but not read yet: the nightly scan gets to 250 a night
    'waiting_scan', (select count(*) from open_places o
                      where o.signals_checked_at is null and not o.coworking),
    'dismissed', (select count(*) from public.candidate_decisions c
                   where c.decision = 'dismissed')
  ) into out;

  return out;
end $$;
revoke all on function public.admin_candidates(text, integer, integer)
  from public, anon;
grant execute on function public.admin_candidates(text, integer, integer)
  to authenticated;

-- 4. Not for the site: off the list, with the reason kept.
create or replace function public.candidate_dismiss(
  p_place  text,
  p_reason text,
  p_note   text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  if coalesce(trim(p_place), '') = '' then
    raise exception 'no place given';
  end if;
  insert into public.candidate_decisions
    (google_place_id, decision, name, reason, note, decided_by)
  select p_place, 'dismissed', d.name,
         nullif(left(trim(coalesce(p_reason, '')), 120), ''),
         nullif(left(trim(coalesce(p_note, '')), 500), ''),
         auth.uid()
    from (select 1) one
    left join public.discovered_places d on d.google_place_id = p_place
  on conflict (google_place_id) do update
     set decision = 'dismissed',
         reason = excluded.reason,
         note = excluded.note,
         decided_by = excluded.decided_by,
         decided_at = now()
   where public.candidate_decisions.decision = 'dismissed';
end $$;
revoke all on function public.candidate_dismiss(text, text, text) from public, anon;
grant execute on function public.candidate_dismiss(text, text, text) to authenticated;

-- 5. Bring one back onto the list.
create or replace function public.candidate_restore(p_place text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  delete from public.candidate_decisions
   where google_place_id = p_place and decision = 'dismissed';
end $$;
revoke all on function public.candidate_restore(text) from public, anon;
grant execute on function public.candidate_restore(text) to authenticated;

-- 6. The places turned down, newest first, for the way back.
create or replace function public.admin_candidates_dismissed(p_limit integer default 100)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'google_place_id', x.google_place_id,
             'name', x.name,
             'reason', x.reason,
             'note', x.note,
             'decided_at', x.decided_at)
             order by x.decided_at desc)
      from (select c.google_place_id, c.name, c.reason, c.note, c.decided_at
              from public.candidate_decisions c
             where c.decision = 'dismissed'
             order by c.decided_at desc
             limit greatest(1, least(coalesce(p_limit, 100), 500))) x),
    '[]'::jsonb);
end $$;
revoke all on function public.admin_candidates_dismissed(integer) from public, anon;
grant execute on function public.admin_candidates_dismissed(integer) to authenticated;

-- 7. Queue for the site: the place becomes a space, already queued,
--    exactly as if a founder had tapped Queue on a new space. The
--    website push is nudged by the trigger that already watches the
--    spaces table.
--
--    p carries what the app read from Google at that moment (city,
--    country, website), each optional. The city falls back to the
--    nearest city page, so a space is never filed without one when
--    the site can name it.
create or replace function public.candidate_queue(p_place text,
                                                  p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d      public.discovered_places%rowtype;
  v_id   uuid;
  v_name text;
  v_city text;
  v_type text;
  near   record;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;

  select * into d from public.discovered_places where google_place_id = p_place;
  if not found then
    raise exception 'That place is no longer on the list.';
  end if;

  -- Already a space (someone reviewed it in the meantime): change
  -- nothing, just say so.
  select id, name into v_id, v_name
    from public.venues where google_place_id = p_place;
  if v_id is not null then
    return jsonb_build_object('venue_id', v_id, 'name', v_name,
                              'existed', true);
  end if;

  select * into near from public.candidate_region(d.lat, d.lng);

  v_city := coalesce(
    nullif(left(trim(coalesce(p->>'city', '')), 120), ''),
    near.region_name,
    'Unknown');
  v_type := case
    when coalesce(d.primary_type, '') = 'coworking_space'
      or d.name ~* 'cowork|co-work|co work|workspace|work ?space|work ?hub|wework'
    then 'coworking' else 'cafe' end;

  insert into public.venues (
    name, type, city, country, website, google_place_id, lat, lng,
    google_rating_snapshot, google_reviews_snapshot,
    status, website_status, source, created_by)
  values (
    d.name,
    v_type,
    v_city,
    coalesce(nullif(left(trim(coalesce(p->>'country', '')), 120), ''),
             near.region_country),
    nullif(left(trim(coalesce(p->>'website', '')), 300), ''),
    d.google_place_id,
    d.lat,
    d.lng,
    d.rating,
    d.user_rating_count,
    'verified',
    'queued',
    'candidate',
    auth.uid())
  returning id into v_id;

  insert into public.candidate_decisions
    (google_place_id, decision, name, venue_id, decided_by)
  values (d.google_place_id, 'queued', d.name, v_id, auth.uid())
  on conflict (google_place_id) do update
     set decision = 'queued',
         venue_id = excluded.venue_id,
         reason = null,
         note = null,
         decided_by = excluded.decided_by,
         decided_at = now()
   where public.candidate_decisions.google_place_id = excluded.google_place_id;

  return jsonb_build_object('venue_id', v_id, 'name', d.name,
                            'city', v_city, 'type', v_type,
                            'existed', false);
end $$;
revoke all on function public.candidate_queue(text, jsonb) from public, anon;
grant execute on function public.candidate_queue(text, jsonb) to authenticated;
