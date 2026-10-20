-- ============================================================
-- Migration 189: ask Claude which Region a space belongs to.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 20 Oct 2026, adding two Florida spaces (Daytona Beach,
-- Ocala) with "Region: Not matched": "can you set it similar to how to
-- choose a location, in terms of ask claude etc".
--
-- The same pattern as migration 169 (Locations):
--   * admin_region_help(space): what we know about the space (Google's
--     city, county, state and country for it) and the nearest Regions
--     on the site with their distance, plus a first verdict: the
--     nearest Region when it is close, else "probably a new Region".
--   * admin_region_ask(space) sends Claude all of that, the naming
--     style of the Regions in that country, and the founder's earlier
--     Region choices with his reasons. The call goes out through pg_net;
--     the app reads the answer with admin_region_answer(ask).
--   * Claude answers with up to three options, most likely first: an
--     existing Region, or a new Region named the site's way (in the US
--     "City, ST", like "Duluth, MN"), with its state.
--   * admin_region_ask_chosen(ask, ...) keeps what the founder chose
--     and why; later questions carry those choices.
--
-- Uses the same Claude key and model as migration 169 (Supabase Vault:
-- anthropic_api_key, anthropic_model). At most 50 questions a day.
-- Nothing here writes to a space or the website.
-- Safe to apply twice.
-- ============================================================

create table if not exists public.region_asks (
  id          bigserial primary key,
  venue_id    uuid not null references public.venues(id) on delete cascade,
  country     text,
  asked_by    uuid default auth.uid(),
  asked_at    timestamptz not null default now(),
  request_id  bigint,
  answer      jsonb,
  error       text,
  done_at     timestamptz,
  chosen      jsonb,
  chosen_at   timestamptz
);
create index if not exists idx_region_asks_venue
  on public.region_asks (venue_id, asked_at desc);
create index if not exists idx_region_asks_chosen
  on public.region_asks (chosen_at desc) where chosen_at is not null;
alter table public.region_asks enable row level security;
-- No policies: read and written only through the functions below.

-- One part of Google's address for a space ("locality",
-- "administrative_area_level_1", ...), long or short form.
create or replace function public.region_addr_part(
  p_details jsonb, p_type text, p_short boolean default false)
returns text language sql immutable as $$
  select nullif(btrim(coalesce(
           case when p_short then c ->> 'shortText' end,
           c ->> 'longText', c ->> 'shortText')), '')
    from jsonb_array_elements(
           case when jsonb_typeof(p_details -> 'addressComponents') = 'array'
                then p_details -> 'addressComponents' else '[]'::jsonb end) c
   where coalesce(c -> 'types', '[]'::jsonb) ? p_type
   limit 1;
$$;

-- ------------------------------------------------ what we know
create or replace function public.admin_region_help(p_venue uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v        record;
  g        jsonb;
  city     text;
  county   text;
  st       text;
  st_short text;
  ctry     text;
  regs     jsonb;
  near     jsonb;
  verdict  jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select x.id, x.name, x.type, x.lat, x.lng, x.city, x.country,
         x.neighbourhood, x.g_details
    into v from public.venues x where x.id = p_venue;
  if v.id is null then
    raise exception 'No such space.';
  end if;
  g := coalesce(v.g_details, '{}'::jsonb);
  city := coalesce(public.region_addr_part(g, 'locality'),
                   public.region_addr_part(g, 'postal_town'),
                   nullif(btrim(coalesce(v.city, '')), ''));
  county := public.region_addr_part(g, 'administrative_area_level_2');
  st := public.region_addr_part(g, 'administrative_area_level_1');
  st_short := public.region_addr_part(g, 'administrative_area_level_1', true);
  ctry := coalesce(nullif(btrim(coalesce(v.country, '')), ''),
                   public.region_addr_part(g, 'country'));

  -- The nearest Regions on the site, any country (a border town can
  -- belong to the next country's city), nearest first.
  if v.lat is not null and v.lng is not null then
    select coalesce(jsonb_agg(t order by t.km), '[]'::jsonb) into regs
      from (select r.id, r.name, r.slug, r.country,
                   round(public.km_between(v.lat, v.lng, r.lat, r.lng)::numeric, 1) as km
              from public.webflow_regions r
             where r.lat is not null and r.lng is not null
               and r.updated_at > now() - interval '3 days'
             order by public.km_between(v.lat, v.lng, r.lat, r.lng)
             limit 12) t;
  else
    regs := '[]'::jsonb;
  end if;

  near := regs -> 0;
  verdict := case
    when near is null then jsonb_build_object(
      'verdict', 'none',
      'why', 'The space has no map position, so the nearest Regions '
             'cannot be worked out.')
    when (near ->> 'km')::numeric <= 25 then jsonb_build_object(
      'verdict', 'suggest',
      'region_id', near ->> 'id',
      'region', near ->> 'name',
      'why', format('%s is the nearest Region, %s km away.',
                    near ->> 'name', near ->> 'km'))
    else jsonb_build_object(
      'verdict', 'none',
      'why', format('The nearest Region, %s, is %s km away, so this '
                    'probably needs a new Region.',
                    near ->> 'name', near ->> 'km'))
  end;

  return jsonb_build_object(
    'venue', jsonb_strip_nulls(jsonb_build_object(
      'id', v.id, 'name', v.name, 'type', v.type,
      'lat', v.lat, 'lng', v.lng,
      'address', nullif(btrim(coalesce(g ->> 'formattedAddress', '')), ''),
      'city', city, 'county', county,
      'state', st, 'state_short', st_short, 'country', ctry)),
    'regions', regs,
    'verdict', verdict);
end $$;
revoke all on function public.admin_region_help(uuid) from public, anon;
grant execute on function public.admin_region_help(uuid) to authenticated;

-- ------------------------------------------------ the question
create or replace function public.admin_region_ask(p_venue uuid)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  k        text;
  model    text;
  help     jsonb;
  vv       jsonb;
  ctry     text;
  nearby   text;
  examples text;
  past     text;
  prompt   text;
  req      bigint;
  ask_id   bigint;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select decrypted_secret into k
    from vault.decrypted_secrets where name = 'anthropic_api_key' limit 1;
  if nullif(btrim(coalesce(k, '')), '') is null then
    raise exception 'No Claude key in the Supabase Vault yet (anthropic_api_key).';
  end if;
  select nullif(btrim(decrypted_secret), '') into model
    from vault.decrypted_secrets where name = 'anthropic_model' limit 1;
  model := coalesce(model, 'claude-sonnet-4-5');
  if (select count(*) from public.region_asks
       where asked_at > now() - interval '1 day') >= 50 then
    raise exception 'Fifty questions today already. More tomorrow.';
  end if;

  help := public.admin_region_help(p_venue);
  vv := help -> 'venue';
  ctry := vv ->> 'country';

  select string_agg(format('- %s | %s | %s km away | page address /region/%s',
                           r ->> 'name', coalesce(r ->> 'country', '?'),
                           r ->> 'km', coalesce(r ->> 'slug', '?')),
                    E'\n') into nearby
    from jsonb_array_elements(coalesce(help -> 'regions', '[]'::jsonb)) r;

  -- How the Regions of this country are named on the site.
  select string_agg(format('- %s (/region/%s)', t.name, t.slug), E'\n') into examples
    from (select r.name, r.slug
            from public.webflow_regions r
           where lower(btrim(coalesce(r.country, ''))) = lower(btrim(coalesce(ctry, '')))
             and r.updated_at > now() - interval '3 days'
           order by r.name
           limit 15) t;

  -- The founder's earlier Region choices, this country first.
  select string_agg(format('- %s (%s) | you offered: %s | Jonathan chose: %s%s',
                           x.name,
                           concat_ws(', ', public.region_addr_part(x.g_details, 'locality'),
                                     public.region_addr_part(x.g_details, 'administrative_area_level_1'),
                                     a.country),
                           coalesce((select string_agg(o ->> 'name', ', ')
                                       from jsonb_array_elements(coalesce(a.answer -> 'options', '[]'::jsonb)) o),
                                    'nothing'),
                           coalesce(nullif(a.chosen ->> 'name', ''), 'the full list'),
                           coalesce(' | his reason: ' || nullif(btrim(a.chosen ->> 'reason'), ''), '')),
                    E'\n') into past
    from (select * from public.region_asks
           where chosen_at is not null
           order by (lower(coalesce(country, '')) = lower(coalesce(ctry, ''))) desc,
                    chosen_at desc
           limit 15) a
    join public.venues x on x.id = a.venue_id;

  prompt := concat_ws(E'\n',
    'Nomadwise is a directory of coworking spaces and work-friendly cafes. Its pages are filed as Country > Region > Location. A Region is a city page: one city or metro area, an island, or a wider rural area. A Location is a neighbourhood inside a Region and is decided separately.',
    '',
    'The place:',
    format('- %s (%s)', vv ->> 'name', coalesce(vv ->> 'type', 'space')),
    format('- Address: %s', coalesce(vv ->> 'address', 'not known')),
    format('- Map position: %s, %s', coalesce(vv ->> 'lat', '?'), coalesce(vv ->> 'lng', '?')),
    format('- Google: city %s, county %s, state or province %s, country %s',
           coalesce(vv ->> 'city', '?'), coalesce(vv ->> 'county', '?'),
           coalesce(vv ->> 'state', '?'), coalesce(ctry, '?')),
    '',
    'The nearest Regions already on the site (name | country | distance | page address):',
    coalesce(nearby, '(none)'),
    '',
    'How Regions in this country are named on the site:',
    coalesce(examples, '(none yet)'),
    '',
    'Earlier Region choices Jonathan made after your suggestions. Follow his way of deciding:',
    coalesce(past, '(none yet)'),
    '',
    'Which Region should this place be filed under?',
    '- Use an existing Region when the place is in that city or its everyday metro area (a suburb, or a town people would call part of that city). Copy its name exactly.',
    '- Otherwise suggest a new Region for the town or city the place is in. A separate town with its own identity gets its own Region, even when a bigger city is within an hour.',
    '- Name a new Region the way this country''s Regions are named. In the United States a Region is named "City, ST" with the two-letter state code, like "Duluth, MN", and the state is never a Region of its own. Give the full state or province name in "state" for a new Region in the United States or India.',
    '- Give one option when it is clear, up to three when people could reasonably differ, most likely first.',
    '',
    'Answer with this JSON and nothing else:',
    '{"options": [{"kind": "existing" or "new", "name": "...", "state": "full state name or empty", "confidence": "high", "medium" or "low", "reason": "one short sentence"}], "note": "one short sentence on the whole answer"}');

  insert into public.region_asks (venue_id, country)
  values (p_venue, ctry) returning id into ask_id;

  select net.http_post(
    url := 'https://api.anthropic.com/v1/messages',
    body := jsonb_build_object(
      'model', model,
      'max_tokens', 700,
      'messages', jsonb_build_array(
        jsonb_build_object('role', 'user', 'content', prompt))),
    headers := jsonb_build_object(
      'x-api-key', k,
      'anthropic-version', '2023-06-01',
      'content-type', 'application/json'),
    timeout_milliseconds := 60000)
  into req;

  update public.region_asks set request_id = req where id = ask_id;
  return ask_id;
end $$;
revoke all on function public.admin_region_ask(uuid) from public, anon;
grant execute on function public.admin_region_ask(uuid) to authenticated;

-- ------------------------------------------------ the answer
-- {status: 'waiting'} until Claude has answered, then {status: 'done',
-- options: [{kind, name, region_id, state, confidence, reason}], note},
-- or {status: 'error', error}.
create or replace function public.admin_region_answer(p_ask bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a      record;
  resp   record;
  body   jsonb;
  txt    text;
  parsed jsonb;
  opts   jsonb := '[]'::jsonb;
  o      jsonb;
  rid    text;
  rname  text;
  kind   text;
  msg    text;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into a from public.region_asks where id = p_ask;
  if a.id is null then
    raise exception 'No such question.';
  end if;
  if a.done_at is not null then
    return case when a.error is not null
                then jsonb_build_object('status', 'error', 'error', a.error)
                else a.answer || jsonb_build_object('status', 'done') end;
  end if;

  select r.status_code, r.content, r.error_msg, r.timed_out into resp
    from net._http_response r where r.id = a.request_id;
  if not found then
    if a.asked_at > now() - interval '90 seconds' then
      return jsonb_build_object('status', 'waiting');
    end if;
    msg := 'No answer came back. Try again.';
  elsif coalesce(resp.timed_out, false) then
    msg := 'Claude took too long to answer. Try again.';
  elsif resp.status_code is distinct from 200 then
    begin
      body := resp.content::jsonb;
    exception when others then
      body := null;
    end;
    msg := 'Claude could not answer (' || coalesce(resp.status_code::text, 'no status') || '): '
           || left(coalesce(body -> 'error' ->> 'message', resp.error_msg, resp.content, ''), 300);
  else
    begin
      body := resp.content::jsonb;
      select string_agg(c ->> 'text', E'\n') into txt
        from jsonb_array_elements(body -> 'content') c
       where c ->> 'type' = 'text';
      parsed := substring(txt from '\{.*\}')::jsonb;
    exception when others then
      parsed := null;
    end;
    if parsed is null then
      msg := 'The answer could not be read. Try again.';
    end if;
  end if;

  if msg is not null then
    update public.region_asks set error = msg, done_at = now() where id = a.id;
    return jsonb_build_object('status', 'error', 'error', msg);
  end if;

  -- Each option matched to the site's Regions by name (this country
  -- first; "Orlando, FL" also finds a Region labelled "Orlando"); an
  -- "existing" one that is not there becomes a new one.
  for o in select * from jsonb_array_elements(
             case when jsonb_typeof(parsed -> 'options') = 'array'
                  then parsed -> 'options' else '[]'::jsonb end)
  loop
    rname := nullif(btrim(coalesce(o ->> 'name', '')), '');
    continue when rname is null;
    rid := null;
    select r.id, r.name into rid, rname
      from public.webflow_regions r
     where r.updated_at > now() - interval '3 days'
       and (public.area_key(r.name) = public.area_key(rname)
            or (public.area_key(split_part(r.name, ',', 1))
                  = public.area_key(split_part(rname, ',', 1))
                and lower(btrim(coalesce(r.country, '')))
                  = lower(btrim(coalesce(a.country, '')))))
     order by (public.area_key(r.name) = public.area_key(rname)) desc,
              (lower(btrim(coalesce(r.country, ''))) = lower(btrim(coalesce(a.country, '')))) desc
     limit 1;
    if rid is null then
      rname := btrim(o ->> 'name');
    end if;
    kind := case when rid is not null then 'existing' else 'new' end;
    continue when exists (select 1 from jsonb_array_elements(opts) e
                           where public.area_key(e ->> 'name') = public.area_key(rname));
    opts := opts || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'kind', kind,
      'name', left(rname, 80),
      'region_id', rid,
      'state', case when kind = 'new'
                    then left(nullif(btrim(coalesce(o ->> 'state', '')), ''), 60) end,
      'confidence', case when o ->> 'confidence' in ('high', 'medium', 'low')
                         then o ->> 'confidence' else 'medium' end,
      'reason', left(nullif(btrim(coalesce(o ->> 'reason', '')), ''), 300))));
    exit when jsonb_array_length(opts) >= 3;
  end loop;

  update public.region_asks
     set answer = jsonb_strip_nulls(jsonb_build_object(
                    'options', opts,
                    'note', left(nullif(btrim(coalesce(parsed ->> 'note', '')), ''), 300))),
         done_at = now()
   where id = a.id
  returning answer into body;
  return body || jsonb_build_object('status', 'done');
end $$;
revoke all on function public.admin_region_answer(bigint) from public, anon;
grant execute on function public.admin_region_answer(bigint) to authenticated;

-- ------------------------------------------------ what the founder chose
-- p_kind: 'existing' or 'new'. The reason is his own words, optional,
-- and goes with every later question.
create or replace function public.admin_region_ask_chosen(
  p_ask bigint, p_kind text, p_name text default null,
  p_region_id text default null, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if p_kind not in ('existing', 'new') then
    raise exception 'Unknown choice.';
  end if;
  update public.region_asks
     set chosen = jsonb_strip_nulls(jsonb_build_object(
                    'kind', p_kind,
                    'name', left(nullif(btrim(coalesce(p_name, '')), ''), 80),
                    'region_id', case when p_kind = 'existing' then p_region_id end,
                    'reason', left(nullif(btrim(coalesce(p_reason, '')), ''), 400))),
         chosen_at = now()
   where id = p_ask;
end $$;
revoke all on function public.admin_region_ask_chosen(bigint, text, text, text, text) from public, anon;
grant execute on function public.admin_region_ask_chosen(bigint, text, text, text, text) to authenticated;
