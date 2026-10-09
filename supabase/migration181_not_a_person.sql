-- 181: a visit to the claim page that was not a person can be marked
-- as such, and the two kinds we know are marked by themselves.
--
-- Jonathan, 9 Oct 2026, on a Claim journeys card ("Arrived through our
-- email, with "ffgbavb-gbyyvaa-jbexybae-abuyf" in the search box"):
-- "This is bot, I have no option". The card offered only "This was
-- me". The same evening an Instagram message to Ohana showed as a
-- visit from Instagram's own servers in Ireland (28 seconds, then
-- gone), and a Facebook message to Library Cafe on 7 Oct did the same.
--
--   bot_visitors          visitors that are machines: why, and whether
--                         found by itself ('auto') or marked ('hand')
--   meta_network(ip)      an address of Instagram's and Facebook's own
--                         servers (Meta's published networks, AS32934).
--                         A person reading a message in Instagram opens
--                         the link from their own connection, never
--                         from these.
--   claim_opened          as migration 167, and: a visit from those
--                         networks, or from a visitor known as a
--                         machine, is noted and nobody is told; a mail
--                         system checking our link (the scrambled name)
--                         is now also noted as a machine
--   claim_lookers         as migration 153, leaving machines out, so
--                         they are not "Looked at the claim page" in
--                         Outreach, nor counted on New pages
--   admin_mark_bot        "Not a person" in Claim journeys (and undo)
--   admin_bot_visitors    the list, for Claim journeys
-- Visits already recorded: every scrambled-name visit from one of our
-- messages, and the two Instagram and Facebook link checks seen
-- (Library Cafe 7 Oct, Ohana 9 Oct), are marked.
-- Pure ASCII. Safe to apply twice.

create table if not exists public.bot_visitors (
  anon_id text primary key,
  why     text not null,
  how     text not null default 'auto' check (how in ('auto', 'hand')),
  at      timestamptz not null default now()
);
alter table public.bot_visitors enable row level security;
revoke all on public.bot_visitors from public, anon, authenticated;

create or replace function public.bot_visitor_note(p_anon text, p_why text)
returns void language plpgsql security definer set search_path = public as $$
declare
  a text := nullif(left(btrim(coalesce(p_anon, '')), 120), '');
begin
  if a is null then return; end if;
  -- one of our own devices stays ours
  if exists (select 1 from public.team_devices t where t.anon_id = a) then return; end if;
  insert into public.bot_visitors (anon_id, why, how)
  values (a, left(coalesce(nullif(btrim(p_why), ''), 'Not a person'), 200), 'auto')
  on conflict (anon_id) do nothing;
exception when others then
  null;
end $$;
revoke all on function public.bot_visitor_note(text, text) from public, anon, authenticated;

create or replace function public.meta_network(p_ip inet)
returns boolean language sql immutable as $$
  select p_ip is not null and p_ip <<= any (array[
    '2a03:2880::/32', '31.13.24.0/21', '31.13.64.0/18', '45.64.40.0/22',
    '57.141.0.0/16', '57.144.0.0/14', '66.220.144.0/20', '69.63.176.0/20',
    '69.171.224.0/19', '74.119.76.0/22', '102.132.96.0/20', '103.4.96.0/22',
    '129.134.0.0/16', '147.75.208.0/20', '157.240.0.0/16', '163.70.128.0/17',
    '173.252.64.0/18', '179.60.192.0/22', '185.60.216.0/22', '185.89.216.0/22',
    '204.15.20.0/22']::inet[]);
$$;
revoke all on function public.meta_network(inet) from public, anon, authenticated;

-- ------------------------------------------------ the claim page ping
create or replace function public.claim_opened(
  p_seed text, p_from text, p_referrer text, p_user_agent text,
  p_geo jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  seed   text := nullif(left(trim(coalesce(p_seed, '')), 200), '');
  frm    text := nullif(left(trim(coalesce(p_from, '')), 300), '');
  ref    text := nullif(left(trim(coalesce(p_referrer, '')), 300), '');
  ua     text := nullif(left(trim(coalesce(p_user_agent, '')), 300), '');
  g      jsonb := case when jsonb_typeof(p_geo) = 'object' then p_geo else '{}'::jsonb end;
  v_id   uuid;
  v_name text;
  v_city text;
  what   text;
  whence text;
  recent int;
  g_cc      text;
  g_country text;
  g_city    text;
  g_lat     double precision;
  g_lng     double precision;
  g_clock   text;
  g_dc      boolean;
  g_visit   text;
  g_anon    text;
  g_near    text;
  g_src     text;
  g_km      integer;
  title     text := 'Claim page opened';
  place     text := '';
  via       text;      -- it followed our own message
  ours      boolean := false;
  marked    boolean := false;
begin
  -- A blocked network (migration 164): nothing is kept, nobody is
  -- told. The check can never stop a real visit: if it fails, the
  -- visit goes on as before.
  begin
    if public.bot_guard_note(
         nullif(left(btrim(coalesce(g ->> 'anon', '')), 120), ''),
         public.request_ip()) is not null then
      return;
    end if;
  exception when others then
    null;
  end;

  -- Not a person (migration 181): Instagram's or Facebook's own
  -- servers opening the link in a message, or a visitor already found
  -- or marked as a machine. Kept as such, and nobody is told.
  begin
    if public.meta_network(public.request_ip()) then
      perform public.bot_visitor_note(g ->> 'anon',
        'Instagram or Facebook checking the link in a message');
      return;
    end if;
    if exists (select 1 from public.bot_visitors b
                where b.anon_id = nullif(btrim(coalesce(g ->> 'anon', '')), '')) then
      return;
    end if;
  exception when others then
    null;
  end;

  insert into public.claim_visits (seed, from_path, referrer, user_agent)
  values (seed, frm, ref, ua);

  select count(*) into recent from public.claim_visits
   where created_at > now() - interval '1 hour';
  if recent > 30 then
    return;
  end if;

  if seed is not null then
    select id, name, city into v_id, v_name, v_city from public.venues
     where webflow_slug = seed or lower(name) = lower(seed)
     order by coalesce(webflow_slug = seed, false) desc,
              (webflow_cms_id is not null) desc, id
     limit 1;
  end if;
  -- An email system checking the link in one of our messages before
  -- the person sees it (8 Oct 2026: "for "ffgbavb-gbyyvaa-jbexybae-
  -- abuyf"", from "email", from Dublin and the Netherlands, minutes
  -- after we wrote to Workland Fahle). Such systems change letters in
  -- the link so that nothing is set off, so the space it names matches
  -- none; a person following our link arrives with the name as we
  -- wrote it. Not a person: nobody is told.
  if v_id is null and seed is not null
     and lower(coalesce(frm, '')) in ('whatsapp', 'email', 'instagram', 'facebook') then
    -- and its visit is shown as such in Claim journeys (migration 181)
    perform public.bot_visitor_note(g ->> 'anon',
      'A mail system checking the link in our message');
    return;
  end if;

  -- The space's line in Outreach, so the visit can be followed up
  -- from there (migration 153). Never in the way of the ping.
  begin
    if v_id is not null then
      perform public.outreach_line_for_venue(v_id);
    end if;
  exception when others then
    null;
  end;

  -- Did it follow our own message? The link we send says where it was
  -- sent (believed only for a space we have written to); without
  -- that, a visit straight to the claim page, or out of a mail or
  -- WhatsApp page, within three days of our writing to the space is
  -- taken as an answer too. Not from a data centre: that is a
  -- machine more often than a person.
  begin
    if v_id is not null and lower(coalesce(frm, '')) in ('whatsapp', 'email', 'instagram', 'facebook')
       and exists (select 1 from public.space_contacts s
                    where s.venue_id = v_id and not s.is_test
                      and s.last_out_at > now() - interval '60 days') then
      via := lower(frm);
    elsif v_id is not null and frm is null
          and coalesce(g ->> 'dc', '') <> 'true'
          and (ref is null
               or ref ~* '^https?://([a-z0-9-]+[.])*(mail[.]google[.]com|outlook[.]live[.]com|outlook[.]office[.]com|mail[.]yahoo[.]com|mail[.]proton[.]me|wa[.]me|whatsapp[.]com)(/|$)'
               or ref ~* '^android-app://(com[.]google[.]android[.]gm|com[.]whatsapp)')
          and exists (select 1 from public.space_contacts s
                       where s.venue_id = v_id and not s.is_test
                         and s.last_out_at > now() - interval '3 days') then
      via := 'after';
    end if;
    -- One of our own devices: only a device that has been signed in
    -- as a founder counts (anyone can send the "internal" mark, so it
    -- is mentioned and nothing more).
    ours := exists (select 1 from public.team_devices t
                     where t.anon_id = nullif(btrim(coalesce(g ->> 'anon', '')), ''));
    marked := coalesce(g ->> 'internal', '') = 'true';
  exception when others then
    via := null; ours := false; marked := false;
  end;

  -- Where the visitor was. Never in the way of the ping either.
  begin
    g_cc := upper(left(btrim(coalesce(g ->> 'cc', '')), 2));
    if g_cc !~ '^[A-Z]{2}$' then
      -- what the server itself saw of the request
      begin
        g_cc := upper(btrim(coalesce(
          current_setting('request.headers', true)::json ->> 'cf-ipcountry', '')));
      exception when others then
        g_cc := '';
      end;
    end if;
    if g_cc !~ '^[A-Z]{2}$' or g_cc in ('XX', 'T1') then
      g_cc := null;
    end if;
    -- (what the visitor's browser sent ends up in a notice: letters,
    -- digits and a few marks only, and not much of it)
    g_country := nullif(left(btrim(regexp_replace(coalesce(g ->> 'country', ''),
                   '[^[:alnum:] .,''()-]', '', 'g')), 40), '');
    if g_country is null then
      g_country := public.claim_geo_country(g_cc);
    end if;
    g_city := nullif(left(btrim(regexp_replace(coalesce(g ->> 'city', ''),
                '[^[:alnum:] .,''()-]', '', 'g')), 40), '');
    if (g ->> 'lat') ~ '^-?[0-9]{1,3}([.][0-9]{1,12})?$' then
      g_lat := (g ->> 'lat')::double precision;
    end if;
    if (g ->> 'lng') ~ '^-?[0-9]{1,3}([.][0-9]{1,12})?$' then
      g_lng := (g ->> 'lng')::double precision;
    end if;
    select t.iso into g_clock from public.tz_countries t
     where t.tz = left(btrim(coalesce(g ->> 'tz', '')), 64);
    g_dc := coalesce(g ->> 'dc', '') = 'true';
    -- a town says nothing without its country
    if g_cc is null then
      g_city := null; g_country := null; g_lat := null; g_lng := null;
    end if;
    g_visit := nullif(left(btrim(coalesce(g ->> 'visit', '')), 80), '');
    g_anon := nullif(left(btrim(coalesce(g ->> 'anon', '')), 120), '');
    if g_cc is not null or g_city is not null or g_clock is not null then
      if v_id is not null then
        select j.near, j.src, j.km into g_near, g_src, g_km
          from public.claim_geo_judge(v_id, g_cc, g_city, g_lat, g_lng, g_clock) j;
        if g_visit is not null then
          insert into public.claim_visit_geo
            (visit, anon_id, venue_id, cc, country, city, km, clock_cc, near, src, dc, via)
          values (g_visit, g_anon, v_id, g_cc, g_country, g_city, g_km, g_clock,
                  g_near, g_src, g_dc, via)
          on conflict (visit) do nothing;
        end if;
      end if;
      place := public.claim_visit_words(via, g_near, g_src, g_city, g_country, g_cc, g_clock, g_dc);
      -- (a VPN's or a data centre's place does not go in the title,
      -- and nor does the place of an answer to our own message)
      if via is null and not (g_dc and coalesce(g_src, 'ip') = 'ip') then
        title := case g_near when 'near' then 'Claim page opened, from nearby'
                             when 'country' then 'Claim page opened, same country'
                             when 'far' then 'Claim page opened, from abroad'
                             else title end;
      end if;
    end if;
  exception when others then
    place := ''; title := 'Claim page opened';
  end;
  -- An answer to our message says so even when nothing is known of
  -- the place; and one of our own devices says that, with the place
  -- as a plain fact. Never in the way of the ping.
  begin
    if ours then
      title := 'Claim page opened (one of ours)';
      place := btrim(coalesce(public.claim_geo_words(
                 null, null, g_city, g_country, g_cc, null, false), '')
               || ' This is one of our own devices.');
    elsif via is not null then
      if coalesce(place, '') = '' then
        place := public.claim_visit_words(via, null, null, null, null, null, null,
                                          coalesce(g ->> 'dc', '') = 'true');
      end if;
      if coalesce(g ->> 'dc', '') <> 'true' then
        title := case via when 'whatsapp' then 'Claim page opened, from our WhatsApp'
                          when 'email' then 'Claim page opened, from our email'
                          when 'instagram' then 'Claim page opened, from our Instagram message'
                          when 'facebook' then 'Claim page opened, from our Facebook message'
                          else 'Claim page opened, after our message' end;
      end if;
    end if;
    if marked and not ours then
      place := btrim(coalesce(place, '')
                     || ' The browser is marked as one of ours (not checked).');
    end if;
  exception when others then
    null;
  end;

  what := case when v_name is not null
               then ' for ' || v_name || coalesce(' in ' || nullif(v_city, ''), '')
               when seed is not null then ' for "' || seed || '"'
               else '' end;
  whence := case when via = 'whatsapp' then 'through the link in our WhatsApp message'
                 when via = 'email' then 'through the link in our email'
                 when via = 'instagram' then 'through the link in our Instagram message'
                 when via = 'facebook' then 'through the link in our Facebook message'
                 when frm like '/%' then 'from nomadwise.io' || frm
                 when frm is not null then 'from "' || frm || '"'
                 when ref is not null then 'from ' ||
                      regexp_replace(ref, '^https?://(www[.])?', '')
                 else 'direct, no referrer' end;

  perform public.notify_phone(
    title,
    'Someone opened the claim page' || what || ', ' || whence || '.'
      || case when coalesce(place, '') <> '' then ' ' || place else '' end,
    'eyes');
end $$;
revoke all on function public.claim_opened(text, text, text, text, jsonb) from public;
grant execute on function public.claim_opened(text, text, text, text, jsonb) to anon, authenticated;

-- ------------------------------------------------ who looked, without machines
create or replace function public.claim_lookers(p_days integer default 60)
returns table (
  venue_id  uuid,
  last_at   timestamptz,
  opens     integer,
  visitors  integer,
  furthest  integer,
  secs      integer,
  from_path text,
  referrer  text,
  device    text
) language sql stable security definer set search_path = public as $$
  with ev as (
    select e.anon_id, e.name, e.props, e.created_at,
           coalesce(nullif(e.props ->> 'visit', ''),
                    e.anon_id || to_char(e.created_at, 'YYYYMMDDHH24')) as visit
      from public.app_events e
     where left(e.name, 6) = 'claim_'
       and e.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 60), 365)))
       and not exists (select 1 from public.team_devices t where t.anon_id = e.anon_id)
       -- nor a machine (migration 181)
       and not exists (select 1 from public.bot_visitors b where b.anon_id = e.anon_id)
  ),
  vis as (
    select min(ev.anon_id) as anon_id, ev.visit,
           min(ev.created_at) as at,
           max(ev.props ->> 'seed') filter (where ev.name = 'claim_opened') as seed,
           (array_agg(ev.props ->> 'space' order by ev.created_at desc)
              filter (where coalesce(ev.props ->> 'space', '') <> ''))[1] as space,
           max(ev.props ->> 'from') filter (where ev.name = 'claim_opened') as from_path,
           max(ev.props ->> 'referrer') filter (where ev.name = 'claim_opened') as referrer,
           max(ev.props ->> 'device') filter (where ev.name = 'claim_opened') as device,
           max(case when ev.name in ('claim_to_payment', 'claim_free') then 3
                    when ev.name = 'claim_step' and ev.props ->> 'to' = 'plan' then 3
                    when ev.name = 'claim_step' and ev.props ->> 'to' = 'about' then 2
                    when ev.name = 'claim_typed' then 2
                    when ev.name = 'claim_step' and ev.props ->> 'to' = 'add_space' then 1
                    -- the step every event says it happened on (a
                    -- form picked up again starts where it was left)
                    when ev.props ->> 'step' = 'plan' then 3
                    when ev.props ->> 'step' = 'about' then 2
                    when ev.props ->> 'step' = 'add_space' then 1
                    else 0 end) as furthest,
           max(case when (ev.props ->> 'secs') ~ '^[0-9]{1,6}$'
                    then (ev.props ->> 'secs')::integer else 0 end) as secs,
           bool_or(ev.name = 'claim_free') as done
      from ev
     group by ev.visit
  ),
  hit as (
    select vis.*, m.id as venue_id
      from vis
     cross join lateral (
            select v.id
              from public.venues v
             where (coalesce(vis.seed, '') <> '' and v.webflow_slug = vis.seed)
                or lower(v.name) = lower(coalesce(nullif(vis.space, ''), nullif(vis.seed, '')))
             order by (coalesce(vis.space, '') <> '' and lower(v.name) = lower(vis.space)) desc,
                      coalesce(v.webflow_slug = vis.seed, false) desc,
                      (v.webflow_cms_id is not null) desc, v.id
             limit 1) m
     where not vis.done
  )
  select h.venue_id, max(h.at), count(*)::integer, count(distinct h.anon_id)::integer,
         max(h.furthest)::integer, max(h.secs)::integer,
         (array_agg(h.from_path order by h.at desc))[1],
         (array_agg(h.referrer order by h.at desc))[1],
         (array_agg(h.device order by h.at desc))[1]
    from hit h
   group by h.venue_id;
$$;
revoke all on function public.claim_lookers(integer) from public, anon, authenticated;
grant execute on function public.claim_lookers(integer) to service_role;

-- ------------------------------------------------ for Claim journeys
create or replace function public.admin_mark_bot(p_anon text, p_bot boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  a text := nullif(left(btrim(coalesce(p_anon, '')), 120), '');
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if a is null then return; end if;
  if p_bot then
    insert into public.bot_visitors (anon_id, why, how)
    values (a, 'Marked as not a person', 'hand')
    on conflict (anon_id) do nothing;
  else
    delete from public.bot_visitors where anon_id = a;
  end if;
end $$;
revoke all on function public.admin_mark_bot(text, boolean) from public, anon;
grant execute on function public.admin_mark_bot(text, boolean) to authenticated;

create or replace function public.admin_bot_visitors()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
                     'anon_id', b.anon_id, 'why', b.why, 'how', b.how, 'at', b.at))
                     from public.bot_visitors b
                    where b.at > now() - interval '120 days'), '[]'::jsonb);
end $$;
revoke all on function public.admin_bot_visitors() from public, anon;
grant execute on function public.admin_bot_visitors() to authenticated;

-- ------------------------------------------------ visits already recorded
-- A mail system's check: a claim link from one of our messages whose
-- name matches no space.
insert into public.bot_visitors (anon_id, why, how, at)
select distinct on (e.anon_id) e.anon_id,
       'A mail system checking the link in our message', 'auto', e.created_at
  from public.app_events e
 where e.name = 'claim_opened'
   and coalesce(e.anon_id, '') <> ''
   and lower(coalesce(e.props ->> 'from', '')) in ('whatsapp', 'email', 'instagram', 'facebook')
   and coalesce(btrim(e.props ->> 'seed'), '') <> ''
   and not exists (select 1 from public.venues v
                    where v.webflow_slug = btrim(e.props ->> 'seed')
                       or lower(v.name) = lower(btrim(e.props ->> 'seed')))
   and not exists (select 1 from public.team_devices t where t.anon_id = e.anon_id)
 order by e.anon_id, e.created_at
on conflict (anon_id) do nothing;

-- Instagram's and Facebook's servers, seen from their addresses in our
-- analytics (Library Cafe 7 Oct, Ohana 9 Oct).
insert into public.bot_visitors (anon_id, why, how) values
  ('anon-1791386314979-1232343', 'Instagram or Facebook checking the link in a message', 'auto'),
  ('anon-1791577130694-7391781', 'Instagram or Facebook checking the link in a message', 'auto')
on conflict (anon_id) do nothing;
