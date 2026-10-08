-- Migration 164: a crawler's networks are blocked, by hand or as soon
-- as one gives itself away.
--
-- 8 Oct 2026, early morning: the claim page was opened 17 times
-- between 05:17 and 06:45 London time, each time from a nomadwise.io
-- page (eSIM, VPN and insurance posts, a few coworking pages, the old
-- "add my business" page), and the founders' phones were told each
-- time. It was a crawler on Tencent's cloud servers in Singapore
-- (addresses 43.172.x.x and 43.173.x.x, AS132203): no referrer, a
-- desktop browser on China time, a new visitor id each visit, and a
-- new address every few seconds (one visit's three steps came from
-- three addresses within two seconds). Nothing like it in the three
-- weeks before. Jonathan: "I want both" (no notices and no counts for
-- such visits; PostHog told it is a bot, done there by hand the same
-- morning), "Is it also possible to block this activity as soon as
-- it's identified".
--
-- What blocking can mean here: the claim page is a static page on
-- GitHub Pages, which serves anybody who asks, so a visit cannot be
-- refused at the door (that would need a service like Cloudflare in
-- front of nomadmaps.io). What is blocked is everything such a visit
-- does on our side: no phone notice, no line in the claim visits, no
-- app events (so no counts, no "Visitor ... finished" summary, no
-- sign of interest in Outreach), and the app sends nothing to PostHog
-- once it knows. Claiming itself is not touched: a real owner on such
-- a network can still claim, and that is still announced.
--
--   blocked_networks        the networks, why, since when, how often
--                           they knocked since (hits)
--   request_ip()            the visitor's address as our server saw it
--                           (null when it cannot be read)
--   blocked_network_of(ip)  the blocked network an address is in
--   bot_guard_note(anon,ip) called by every claim visit and every app
--                           event: says whether the network is blocked,
--                           and blocks one that gives itself away:
--                           ONE visitor whose requests come from THREE
--                           different networks (/24) within two
--                           minutes is a machine with a pool of
--                           addresses, not a person (a phone moving
--                           between wifi and mobile data makes two).
--                           Its /16 networks are then blocked for 90
--                           days and the founders' phones are told
--                           once.
--   request_ip_log          the addresses that check needs, kept
--                           twenty minutes at most and then deleted
--   visit_blocked()         the app asks once per visit; true makes it
--                           silent, like one of our own devices
--   claim_opened            as in 160, with the check first
--   app_events              a blocked network's events are not stored
--   blocked_rows            what was taken out of the tables below
--                           (kept, not thrown away)
--
-- Seeded: 43.172.0.0/15 (Tencent Cloud, Singapore). The crawler's
-- visits of 8 Oct are moved out of claim_visits, app_events and
-- claim_visit_geo (three of them had become signs of interest in
-- Outreach: Tribal Bali, Hellocapitano Lifestyle Cafe, Indigo
-- Specialty Coffee & Bakery).

create table if not exists public.blocked_networks (
  network     cidr primary key,
  label       text not null,
  reason      text,
  source      text not null default 'hand' check (source in ('hand', 'auto')),
  added_at    timestamptz not null default now(),
  expires_at  timestamptz,
  hits        integer not null default 0,
  last_hit_at timestamptz
);
alter table public.blocked_networks enable row level security;

create table if not exists public.request_ip_log (
  id      bigint generated always as identity primary key,
  anon_id text not null,
  ip      inet not null,
  at      timestamptz not null default now()
);
create index if not exists idx_request_ip_log_anon on public.request_ip_log (anon_id, at);
create index if not exists idx_request_ip_log_at on public.request_ip_log (at);
alter table public.request_ip_log enable row level security;

create table if not exists public.blocked_rows (
  id         bigint generated always as identity primary key,
  table_name text not null,
  row_data   jsonb not null,
  reason     text,
  moved_at   timestamptz not null default now()
);
alter table public.blocked_rows enable row level security;

insert into public.blocked_networks (network, label, reason, source)
values ('43.172.0.0/15', 'Tencent Cloud, Singapore',
        'A crawler opened the claim page 17 times on 8 Oct 2026, 05:17 to 06:45 London time, '
        || 'from nomadwise.io pages, with a new address every few seconds.', 'hand')
on conflict (network) do nothing;

-- The visitor's address, as the request reached our server. Only the
-- address Cloudflare (in front of the database's web address) puts on
-- every request is believed: the other address headers can be written
-- by the caller, and anybody could then get somebody else's network
-- blocked. Null when there is none or it is one of the platform's own
-- (private) ones: then nothing is checked and nothing is blocked.
create or replace function public.request_ip()
returns inet language plpgsql stable as $$
declare
  h  json;
  s  text;
  ip inet;
begin
  begin
    h := current_setting('request.headers', true)::json;
  exception when others then
    return null;
  end;
  if h is null then return null; end if;
  s := nullif(btrim(h ->> 'cf-connecting-ip'), '');
  if s is null then return null; end if;
  begin
    ip := s::inet;
  exception when others then
    return null;
  end;
  if ip <<= '10.0.0.0/8'::inet or ip <<= '172.16.0.0/12'::inet
     or ip <<= '192.168.0.0/16'::inet or ip <<= '127.0.0.0/8'::inet
     or ip <<= '100.64.0.0/10'::inet or ip <<= '169.254.0.0/16'::inet
     or ip <<= 'fc00::/7'::inet or ip <<= '::1/128'::inet or ip <<= 'fe80::/10'::inet then
    return null;
  end if;
  return host(ip)::inet;
end $$;
revoke all on function public.request_ip() from public, anon, authenticated;

create or replace function public.blocked_network_of(p_ip inet)
returns cidr language sql stable security definer set search_path = public as $$
  select b.network from public.blocked_networks b
   where p_ip is not null and p_ip <<= b.network
     and (b.expires_at is null or b.expires_at > now())
   order by masklen(b.network) desc
   limit 1;
$$;
revoke all on function public.blocked_network_of(inet) from public, anon, authenticated;

-- See the top of the file. Returns the blocked network the address is
-- in (also when it has just been blocked), or null.
create or replace function public.bot_guard_note(p_anon text, p_ip inet)
returns cidr language plpgsql security definer set search_path = public as $$
declare
  net   cidr;
  n     integer;
  nets  cidr[];
  added integer;
  anon  text := nullif(left(btrim(coalesce(p_anon, '')), 120), '');
begin
  if p_ip is null then return null; end if;
  net := public.blocked_network_of(p_ip);
  if net is not null then
    update public.blocked_networks
       set hits = hits + 1, last_hit_at = now()
     where network = net;
    return net;
  end if;
  if anon is null then return null; end if;

  insert into public.request_ip_log (anon_id, ip) values (anon, p_ip);
  select count(distinct network(set_masklen(l.ip, case when family(l.ip) = 4 then 24 else 48 end)))
    into n
    from public.request_ip_log l
   where l.anon_id = anon and l.at > now() - interval '2 minutes';
  if n < 3 then
    return null;
  end if;

  -- one visitor, three networks in two minutes: block where it came from
  perform pg_advisory_xact_lock(hashtextextended('bot_guard:' || anon, 0));
  select array_agg(distinct network(set_masklen(l.ip, case when family(l.ip) = 4 then 16 else 32 end)))
    into nets
    from public.request_ip_log l
   where l.anon_id = anon and l.at > now() - interval '2 minutes';
  with ins as (
    insert into public.blocked_networks (network, label, reason, source, expires_at)
    select x, 'Found by itself',
           'Visitor ' || right(anon, 6) || ' came from ' || n
             || ' different networks within two minutes.',
           'auto', now() + interval '90 days'
      from unnest(nets) x
     where not exists (select 1 from public.blocked_networks b where x <<= b.network)
    on conflict (network) do nothing
    returning network)
  select count(*) into added from ins;
  if added > 0 then
    perform public.notify_phone(
      'A bot was blocked',
      'Visitor ' || right(anon, 6) || ' came from ' || n
        || ' different networks within two minutes, so it is a machine. '
        || 'Its networks (' || array_to_string(nets, ', ')
        || ') are blocked for 90 days: no more notices or counts from them.',
      'shield');
  end if;
  return public.blocked_network_of(p_ip);
end $$;
revoke all on function public.bot_guard_note(text, inet) from public, anon, authenticated;

-- For the app: is this visit on a blocked network? Asks nothing else
-- and keeps nothing.
create or replace function public.visit_blocked()
returns boolean language sql stable security definer set search_path = public as $$
  select public.blocked_network_of(public.request_ip()) is not null;
$$;
revoke all on function public.visit_blocked() from public;
grant execute on function public.visit_blocked() to anon, authenticated;

-- App events from a blocked network are not stored (and so start no
-- notice and no summary). Never in the way of a real event.
create or replace function public.app_events_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    if public.bot_guard_note(new.anon_id, public.request_ip()) is not null then
      return null;
    end if;
  exception when others then
    null;
  end;
  return new;
end $$;
revoke all on function public.app_events_guard() from public, anon, authenticated;
drop trigger if exists trg_app_events_guard on public.app_events;
create trigger trg_app_events_guard
  before insert on public.app_events
  for each row execute function public.app_events_guard();

-- The addresses are only needed for two minutes: gone after twenty.
do $$
begin
  perform cron.unschedule('bot-guard-forget');
exception when others then null;
end $$;
select cron.schedule('bot-guard-forget', '*/10 * * * *',
  'delete from public.request_ip_log where at < now() - interval ''10 minutes''');

-- ------------------------------------------------ the claim page ping
-- As migration 160, with the network check first.
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

-- ------------------------------------------------ 8 Oct: the crawler's visits moved out
-- Its visitor ids as PostHog recorded them, the times of its claim
-- visits, and the browser it said it was (read from those visits).
do $$
declare
  anons text[] := array[
    'anon-1791433071931-14647467', 'anon-1791433504510-16594679',
    'anon-1791433927547-1319128',  'anon-1791434044032-2340524',
    'anon-1791434419071-13975772', 'anon-1791434420495-13014584',
    'anon-1791434473119-13527150', 'anon-1791434595461-11567065',
    'anon-1791434655151-587572',   'anon-1791434774612-3617788',
    'anon-1791434957931-207175',   'anon-1791434960397-15742927',
    'anon-1791435327614-7048709',  'anon-1791435383299-15143213',
    'anon-1791436542119-4360755',  'anon-1791437088661-13546611',
    'anon-1791437760550-11735004', 'anon-1791437879572-700041',
    'anon-1791438138185-13258601', 'anon-1791438310032-1988243'];
  seen timestamptz[] := array[
    '2026-10-08 04:17:51+00', '2026-10-08 04:25:04+00', '2026-10-08 04:32:07+00',
    '2026-10-08 04:34:04+00', '2026-10-08 04:40:20+00', '2026-10-08 04:41:13+00',
    '2026-10-08 04:43:15+00', '2026-10-08 04:44:15+00', '2026-10-08 04:49:17+00',
    '2026-10-08 04:49:20+00', '2026-10-08 04:55:27+00', '2026-10-08 05:15:42+00',
    '2026-10-08 05:24:48+00', '2026-10-08 05:36:00+00', '2026-10-08 05:37:59+00',
    '2026-10-08 05:42:18+00', '2026-10-08 05:45:10+00']::timestamptz[];
  uas  text[];
  why  text := 'Crawler on Tencent Cloud, Singapore, 8 Oct 2026 (migration 164)';
begin
  -- the browser it said it was: what its known claim visits carried,
  -- and only when that is one and the same (else nothing is guessed)
  select array_agg(distinct cv.user_agent) into uas
    from public.claim_visits cv
   where cv.user_agent is not null and cv.referrer is null
     and exists (select 1 from unnest(seen) t
                  where cv.created_at between t - interval '5 seconds' and t + interval '5 seconds');
  if coalesce(array_length(uas, 1), 0) <> 1 then
    uas := '{}';
  end if;

  -- more of its visitor ids: app arrivals since 04:00 that said the same
  anons := anons || coalesce((
    select array_agg(distinct e.anon_id)
      from public.app_events e
     where e.created_at >= '2026-10-08 04:00+00' and e.created_at < '2026-10-08 18:00+00'
       and e.name = 'app_opened'
       and left(coalesce(e.props ->> 'ua', ''), 160) = any (select left(u, 160) from unnest(uas) u)
       and coalesce(e.props ->> 'referrer', '') = ''), '{}');

  with gone as (
    delete from public.claim_visit_geo g
     where g.at >= '2026-10-08 04:00+00'
       and (g.anon_id = any(anons)
            or g.visit in (select e.props ->> 'visit' from public.app_events e
                            where e.anon_id = any(anons) and e.created_at >= '2026-10-08 04:00+00'))
    returning g.*)
  insert into public.blocked_rows (table_name, row_data, reason)
  select 'claim_visit_geo', to_jsonb(gone), why from gone;

  with gone as (
    delete from public.app_events e
     where e.created_at >= '2026-10-08 04:00+00' and e.anon_id = any(anons)
    returning e.*)
  insert into public.blocked_rows (table_name, row_data, reason)
  select 'app_events', to_jsonb(gone), why from gone;

  with gone as (
    delete from public.claim_visits cv
     where cv.created_at >= '2026-10-08 04:00+00' and cv.created_at < '2026-10-08 18:00+00'
       and cv.referrer is null
       and (exists (select 1 from unnest(seen) t
                     where cv.created_at between t - interval '5 seconds' and t + interval '5 seconds')
            or cv.user_agent = any(uas))
    returning cv.*)
  insert into public.blocked_rows (table_name, row_data, reason)
  select 'claim_visits', to_jsonb(gone), why from gone;
end $$;

-- ------------------------------------------------ for the founders: what the guard holds
-- Whether the database can read the caller's address at all (if not,
-- the guard does nothing), the blocked networks, and what was moved
-- out of the tables.
create or replace function public.admin_bot_guard()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'address_readable', public.request_ip() is not null,
    'networks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'network', b.network::text, 'label', b.label, 'reason', b.reason,
               'source', b.source, 'added_at', b.added_at, 'expires_at', b.expires_at,
               'hits', b.hits, 'last_hit_at', b.last_hit_at) order by b.added_at)
        from public.blocked_networks b), '[]'::jsonb),
    'moved', coalesce((
      select jsonb_object_agg(t.table_name, t.n)
        from (select table_name, count(*) as n from public.blocked_rows group by table_name) t),
      '{}'::jsonb));
end $$;
revoke all on function public.admin_bot_guard() from public, anon;
grant execute on function public.admin_bot_guard() to authenticated;

