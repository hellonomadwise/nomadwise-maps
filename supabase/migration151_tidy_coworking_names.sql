-- Migration 151: "Coworking" and "Cafe", one way, in the names of candidates.
--
-- Jonathan, 6 Oct 2026: a candidate came up as "Espacio Bica Ruzafa
-- COWORKING". Google gives names the way each owner typed them, so the
-- word turns up in block capitals and as "Co-working". By default it
-- should read "Coworking": capital C, no dash. Asked whether a name
-- wholly in capitals should be put in ordinary capitals: "Only words
-- like Coworking or Cafe". So the words that say what kind of place it
-- is are put right when they come in block capitals, and the rest of a
-- name (which may be meant to be in capitals) is left as it is.
--
-- The name is tidied where a candidate is shown and where it is put in
-- the queue, so the page that gets made carries the tidy name. The
-- copy of Google's answer (discovered_places) is left as Google gave
-- it: the map writes to that table too, and the matching of names
-- against the listing sites reads it. Pages already on the site or in
-- the queue keep their names.

create or replace function public.tidy_space_name(p_name text)
returns text language plpgsql immutable as $$
declare
  o text := p_name;
  w text;
begin
  if o is null then
    return null;
  end if;
  -- "Co-working", with a dash after "co" (the plain one, or one of the
  -- look-alike dashes), in any capitals
  o := regexp_replace(o, '\mco[-\u2010\u2011\u2012\u2013]working\M',
                      'Coworking', 'gi');
  -- "COWORKING", "CoWorking": the word with a capital anywhere in it.
  -- A name typed all in small letters keeps its small "coworking".
  o := regexp_replace(o, '\m(?=[a-z]*[A-Z])[Cc][Oo][Ww][Oo][Rr][Kk][Ii][Nn][Gg]\M',
                      'Coworking', 'g');
  -- The other words for a kind of place, only when in block capitals.
  -- To add one, add it here.
  foreach w in array array[
    'Cowork', 'Coliving', 'Workspace', 'Space', 'Hub', 'Office',
    'Cafe', 'Coffee', 'Bakery', 'Roasters', 'Kitchen', 'Bar',
    'Lounge', 'Studio', 'Hostel', 'Hotel']
  loop
    -- (not when stuck to a dot: "1SMART.SPACE" is a name, not a word)
    o := regexp_replace(o, '(?<![\w.])' || upper(w) || '(?![\w.])', w, 'g');
  end loop;
  -- "CAFE" with its accent
  o := regexp_replace(o, '(?<![\w.])CAF\u00c9(?![\w.])', U&'Caf\00e9', 'g');
  return o;
end $$;
revoke all on function public.tidy_space_name(text) from public, anon;
grant execute on function public.tidy_space_name(text) to authenticated, service_role;

-- ------------------------------------------------ the candidates list
-- As migration 140; only the name shown is tidied.
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
               'name', public.tidy_space_name(g.name),
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

-- ------------------------------------------------ the ones turned down
-- As migration 129; only the name shown is tidied.
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
             'name', public.tidy_space_name(x.name),
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

-- ------------------------------------------------ into the queue
-- As migration 129; the new space is named with the tidy name.
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
  -- the name the page will carry: "Coworking", one way (migration 151)
  d.name := public.tidy_space_name(d.name);

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
