-- 169: ask Claude which Location a space is in, offer the options,
-- and learn from what the founder chooses.
--
-- Jonathan, 8 Oct 2026, on the map of the spaces nearby ("No Location
-- suggested"): "to find out what location to assign a place as, maybe
-- its possible to run a search to ask claude or google to check". He
-- chose Claude. Then: "if there is a situation where it could be
-- multiple options, giving me a choice would be great, I can then make
-- the selection, and then if you can learn each time so that over time
-- you get it more right", and "I could even provide a reason why I
-- selected the option I chose."
--
-- How it works:
--   * admin_location_ask(space) sends Claude what we know: the space,
--     its map position, Google's names for its area, its Region and
--     that Region's Locations, the listed places of the Region with the
--     Location each one has, and the founder's earlier choices (with
--     his reasons). The call goes out through pg_net; the app asks for
--     the answer a few seconds later with admin_location_answer(ask).
--   * Claude answers with up to three options, most likely first: an
--     existing Location, or a well-known area name to create as a new
--     Location. No options means the Region page alone.
--   * admin_location_ask_chosen(ask, ...) keeps what the founder chose
--     and why. Every later question in that Region carries those
--     choices, and the ones where he chose differently from Claude's
--     first option are sent for every Region, so the same mistake is
--     not made twice.
--
-- Needs a Claude API key in the Supabase Vault, named anthropic_api_key
-- (the founder adds it; it never goes in a file). The model can be
-- changed with a Vault entry named anthropic_model.
-- At most 50 questions a day, so a loop can never run up a bill.
-- Safe to apply twice.

create table if not exists public.location_asks (
  id          bigserial primary key,
  venue_id    uuid not null references public.venues(id) on delete cascade,
  region_id   text,
  asked_by    uuid default auth.uid(),
  asked_at    timestamptz not null default now(),
  request_id  bigint,
  answer      jsonb,
  error       text,
  done_at     timestamptz,
  chosen      jsonb,
  chosen_at   timestamptz
);
create index if not exists idx_location_asks_venue
  on public.location_asks (venue_id, asked_at desc);
create index if not exists idx_location_asks_region
  on public.location_asks (region_id) where chosen_at is not null;
alter table public.location_asks enable row level security;
-- No policies: read and written only through the functions below.

-- ------------------------------------------------ the question
create or replace function public.admin_location_ask(
  p_venue uuid, p_region text default null, p_names text[] default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  k       text;
  model   text;
  v       record;
  help    jsonb;
  reg     jsonb;
  rid     text;
  locs    text;
  places  text;
  past    text;
  lessons text;
  names   text;
  prompt  text;
  req     bigint;
  ask_id  bigint;
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
  if (select count(*) from public.location_asks
       where asked_at > now() - interval '1 day') >= 50 then
    raise exception 'Fifty questions today already. More tomorrow.';
  end if;

  select x.id, x.name, x.type, x.lat, x.lng, x.city, x.country, x.neighbourhood
    into v from public.venues x where x.id = p_venue;
  if v.id is null then
    raise exception 'No such space.';
  end if;

  help := public.admin_location_help(p_venue, p_region, p_names);
  reg := help -> 'region';
  rid := reg ->> 'id';
  if rid is null then
    raise exception 'Pick a Region first: Locations sit inside a Region.';
  end if;

  select string_agg(n, ', ') into names
    from jsonb_array_elements_text(coalesce(help -> 'area_names', '[]'::jsonb)) a(n);

  select string_agg('- ' || l.name, E'\n' order by l.name) into locs
    from public.webflow_locations l
   where l.region_id = rid
     and l.updated_at > now() - interval '3 days';

  -- The listed places of the Region with their Location, nearest first.
  select string_agg(format('- %s | %s, %s | %s km away | %s',
                           t.name, round(t.lat::numeric, 5), round(t.lng::numeric, 5),
                           round(t.km::numeric, 1), coalesce(t.loc, 'no Location')),
                    E'\n' order by t.km) into places
    from (select x.name, x.lat, x.lng, l.name as loc,
                 public.km_between(v.lat, v.lng, x.lat, x.lng) as km
            from public.venues x
            left join public.webflow_locations l on l.id = x.webflow_location_id
           where x.id <> p_venue
             and x.webflow_cms_id is not null
             and x.website_status = 'released'
             and x.webflow_region_id = rid
             and x.lat is not null and x.lng is not null
             and v.lat is not null and v.lng is not null
             and coalesce(x.business_status, '') <> 'CLOSED_PERMANENTLY'
           order by 5
           limit 30) t;

  -- The founder's earlier choices in this Region.
  select string_agg(format('- %s | %s, %s | you offered: %s | Jonathan chose: %s%s',
                           x.name, round(x.lat::numeric, 5), round(x.lng::numeric, 5),
                           coalesce((select string_agg(o ->> 'name', ', ')
                                       from jsonb_array_elements(coalesce(a.answer -> 'options', '[]'::jsonb)) o),
                                    'nothing'),
                           coalesce(nullif(a.chosen ->> 'name', ''), 'no Location (Region page only)'),
                           coalesce(' | his reason: ' || nullif(btrim(a.chosen ->> 'reason'), ''), '')),
                    E'\n' order by a.chosen_at desc) into past
    from (select * from public.location_asks
           where region_id = rid and chosen_at is not null
           order by chosen_at desc limit 15) a
    join public.venues x on x.id = a.venue_id;

  -- Anywhere else: where he chose differently from the first option.
  select string_agg(format('- %s in %s: you said %s first; Jonathan chose %s%s',
                           x.name, coalesce(g.name, 'its Region'),
                           coalesce(nullif(a.answer -> 'options' -> 0 ->> 'name', ''), 'no Location'),
                           coalesce(nullif(a.chosen ->> 'name', ''), 'no Location (Region page only)'),
                           coalesce(' | his reason: ' || nullif(btrim(a.chosen ->> 'reason'), ''), '')),
                    E'\n' order by a.chosen_at desc) into lessons
    from (select * from public.location_asks
           where chosen_at is not null
             and region_id is distinct from rid
             and lower(coalesce(chosen ->> 'name', ''))
                 is distinct from lower(coalesce(answer -> 'options' -> 0 ->> 'name', ''))
           order by chosen_at desc limit 10) a
    join public.venues x on x.id = a.venue_id
    left join public.webflow_regions g on g.id = a.region_id;

  prompt := concat_ws(E'\n',
    'Nomadwise is a directory of coworking spaces and work-friendly cafes. Its pages are filed as Country > Region (a city, island or wider area) > Location (a neighbourhood or district inside the Region). A Location is optional: a place can sit under the Region page alone.',
    '',
    'The place:',
    format('- %s (%s)', v.name, coalesce(v.type, 'space')),
    format('- Map position: %s, %s', v.lat, v.lng),
    format('- Google''s names for its area: %s', coalesce(names, 'none')),
    format('- Region: %s, %s', reg ->> 'name', coalesce(reg ->> 'country', v.country, '')),
    '',
    'Locations that already exist in this Region:',
    coalesce(locs, '(none yet)'),
    '',
    'Places already listed in this Region and the Location each one was given (name | map position | distance | Location):',
    coalesce(places, '(none yet)'),
    '',
    'Earlier choices Jonathan made in this Region, after your suggestions. Follow his way of deciding:',
    coalesce(past, '(none yet)'),
    '',
    'Times elsewhere when Jonathan chose differently from your first option. Learn from them:',
    coalesce(lessons, '(none yet)'),
    '',
    'Which Location would most people say this place is in?',
    '- Give one option when it is clear. When people could reasonably say more than one, give up to three, most likely first.',
    '- An option is either an existing Location (copy its name exactly) or, when none of them fits, a well-known neighbourhood or district name that most people use for this exact spot, which could be created as a new Location.',
    '- Only name areas you are sure of. When nothing fits, give no options: the Region page alone is a good answer.',
    '',
    'Answer with this JSON and nothing else:',
    '{"options": [{"kind": "existing" or "new", "name": "...", "confidence": "high", "medium" or "low", "reason": "one short sentence"}], "note": "one short sentence on the whole answer"}');

  insert into public.location_asks (venue_id, region_id)
  values (p_venue, rid) returning id into ask_id;

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

  update public.location_asks set request_id = req where id = ask_id;
  return ask_id;
end $$;
revoke all on function public.admin_location_ask(uuid, text, text[]) from public, anon;
grant execute on function public.admin_location_ask(uuid, text, text[]) to authenticated;

-- ------------------------------------------------ the answer
-- {status: 'waiting'} until Claude has answered, then {status: 'done',
-- options: [{kind, name, location_id, confidence, reason}], note}, or
-- {status: 'error', error}.
create or replace function public.admin_location_answer(p_ask bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a      record;
  resp   record;
  body   jsonb;
  txt    text;
  parsed jsonb;
  opts   jsonb := '[]'::jsonb;
  o      jsonb;
  lid    text;
  lname  text;
  kind   text;
  msg    text;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into a from public.location_asks where id = p_ask;
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
    update public.location_asks set error = msg, done_at = now() where id = a.id;
    return jsonb_build_object('status', 'error', 'error', msg);
  end if;

  -- Each option matched to the Region's Locations by name; an
  -- "existing" one that is not there becomes a new one.
  for o in select * from jsonb_array_elements(
             case when jsonb_typeof(parsed -> 'options') = 'array'
                  then parsed -> 'options' else '[]'::jsonb end)
  loop
    lname := nullif(btrim(coalesce(o ->> 'name', '')), '');
    continue when lname is null;
    lid := null;
    select l.id, l.name into lid, lname
      from public.webflow_locations l
     where l.region_id = a.region_id
       and l.updated_at > now() - interval '3 days'
       and public.area_key(l.name) = public.area_key(lname)
     limit 1;
    if lid is null then
      lname := btrim(o ->> 'name');
    end if;
    kind := case when lid is not null then 'existing' else 'new' end;
    continue when exists (select 1 from jsonb_array_elements(opts) e
                           where public.area_key(e ->> 'name') = public.area_key(lname));
    opts := opts || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'kind', kind,
      'name', left(lname, 80),
      'location_id', lid,
      'confidence', case when o ->> 'confidence' in ('high', 'medium', 'low')
                         then o ->> 'confidence' else 'medium' end,
      'reason', left(nullif(btrim(coalesce(o ->> 'reason', '')), ''), 300))));
    exit when jsonb_array_length(opts) >= 3;
  end loop;

  update public.location_asks
     set answer = jsonb_strip_nulls(jsonb_build_object(
                    'options', opts,
                    'note', left(nullif(btrim(coalesce(parsed ->> 'note', '')), ''), 300))),
         done_at = now()
   where id = a.id
  returning answer into body;
  return body || jsonb_build_object('status', 'done');
end $$;
revoke all on function public.admin_location_answer(bigint) from public, anon;
grant execute on function public.admin_location_answer(bigint) to authenticated;

-- ------------------------------------------------ what the founder chose
-- p_kind: 'existing', 'new' or 'none'. The reason is his own words,
-- optional, and goes with every later question.
create or replace function public.admin_location_ask_chosen(
  p_ask bigint, p_kind text, p_name text default null,
  p_location_id text default null, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if p_kind not in ('existing', 'new', 'none') then
    raise exception 'Unknown choice.';
  end if;
  update public.location_asks
     set chosen = jsonb_strip_nulls(jsonb_build_object(
                    'kind', p_kind,
                    'name', case when p_kind = 'none' then null
                                 else left(nullif(btrim(coalesce(p_name, '')), ''), 80) end,
                    'location_id', case when p_kind = 'existing' then p_location_id end,
                    'reason', left(nullif(btrim(coalesce(p_reason, '')), ''), 400))),
         chosen_at = now()
   where id = p_ask;
end $$;
revoke all on function public.admin_location_ask_chosen(bigint, text, text, text, text) from public, anon;
grant execute on function public.admin_location_ask_chosen(bigint, text, text, text, text) to authenticated;
