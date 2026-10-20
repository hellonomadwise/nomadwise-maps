-- ============================================================
-- Migration 190: our own chat on nomadwise.io, answered by Claude,
-- watched and taken over from the Chats screen in Nomad Maps.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 20 Oct 2026, after removing tawk.to (it had collected
-- enquiries since March that nobody saw): "A chat box on
-- nomadwise.io, powered by Claude, that sounds human and speaks in
-- the Nomadwise voice. For space owners: it guides them through the
-- claim flow towards Verified. For users: it answers questions about
-- spaces and the site. A phone alert to me whenever someone starts a
-- chat. A Chats inbox in the nomadmaps admin, in the same tick-off
-- style as the control centre. From there I can take over any
-- conversation and reply live, or by email if they've left the site.
-- Every conversation saved." And: keep it light, the database is
-- over its free data allowance.
--
-- How it works:
--   * The chat box (nomadmaps.io/chat.js, on every nomadwise.io page)
--     keeps a random key in the visitor's browser. That key is the
--     only way to read or write that chat.
--   * site_chat_send: the visitor writes. The first message tells
--     the founders' phones. While the assistant is answering (mode
--     'bot'), the conversation goes to Claude through pg_net with
--     what the page they are on is about: the space, or the spaces
--     of that Region or Location, from our own data, and any Region
--     they name.
--   * site_chat_poll: the box asks for anything new while it is open
--     (every few seconds while an answer is coming, slower otherwise,
--     and not at all once closed). Each answer is a few hundred bytes.
--   * The assistant answers in JSON: the reply, whether they run a
--     space or are looking for one, whether a person is needed, and
--     an email address if they gave one. "Needs a person" goes to the
--     top of the inbox and tells the phones.
--   * The assistant says it is an assistant if asked, never claims to
--     be a person, and never names the model behind it.
--   * A founder writing in a chat takes it over (mode 'team'): the
--     assistant stops, the visitor sees the reply live. If they have
--     left the site and gave an email, what we wrote is emailed to
--     them (site_chat_email_sync, every two minutes, as the owner
--     chat does), a minute after the last message.
--   * Limits, so the box can never run up a bill or be abused
--     (Jonathan: "can you put tighter restrictions in place if someone
--     hammers it"):
--       the assistant: 60 answers a day and 1,000 a month in all, 12
--         in one chat, 20 a day for one connection, 400 tokens each;
--       a connection: 15 messages an hour, 40 a day, 3 new chats a
--         day, one message every 3 seconds, the same message twice in
--         a row is ignored;
--       in all: 20 new chats an hour, 80 a day; 800 characters a
--         message; blocked networks (migration 164) get nothing.
--     Past an assistant limit the visitor gets a kind holding message
--     asking for an email, which costs nothing, and a founder answers.
--     The first time a day an overall limit is reached, the phones are
--     told once (site_chat_alerts).
--
-- Uses the Claude key and model already in Vault (migration 169:
-- anthropic_api_key, anthropic_model).
-- Nothing here changes an existing table or function.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create table if not exists public.site_chats (
  id            uuid primary key default gen_random_uuid(),
  token         uuid not null unique,
  started_at    timestamptz not null default now(),
  last_at       timestamptz not null default now(),
  last_seen_at  timestamptz,
  page_url      text,
  page_title    text,
  first_page    text,
  visitor_name  text,
  visitor_email text,
  who           text check (who in ('owner', 'visitor')),
  venue_id      uuid references public.venues(id) on delete set null,
  mode          text not null default 'bot' check (mode in ('bot', 'team')),
  needs_team    boolean not null default false,
  status        text not null default 'open' check (status in ('open', 'done')),
  team_seen_at  timestamptz,
  done_at       timestamptz,
  ip_hash       text,
  pending_req   bigint,
  pending_upto  bigint,
  pending_since timestamptz,
  bot_replies   integer not null default 0,
  visitor_msgs  integer not null default 0,
  note          text
);
create index if not exists idx_site_chats_last on public.site_chats (last_at desc);
create index if not exists idx_site_chats_ip on public.site_chats (ip_hash, started_at);

create table if not exists public.site_chat_messages (
  id         bigserial primary key,
  chat_id    uuid not null references public.site_chats(id) on delete cascade,
  role       text not null check (role in ('visitor', 'bot', 'team')),
  author     text,
  body       text not null check (char_length(body) between 1 and 4000),
  at         timestamptz not null default now(),
  ip_hash    text,
  read_at    timestamptz,
  emailed_at timestamptz
);
create index if not exists idx_site_chat_messages_chat on public.site_chat_messages (chat_id, id);
create index if not exists idx_site_chat_messages_at on public.site_chat_messages (role, at);
create index if not exists idx_site_chat_messages_ip on public.site_chat_messages (ip_hash, at)
  where role = 'visitor';

-- One notice a day at most when an overall limit is reached.
create table if not exists public.site_chat_alerts (
  day  date not null,
  kind text not null,
  primary key (day, kind)
);
alter table public.site_chat_alerts enable row level security;

alter table public.site_chats enable row level security;
alter table public.site_chat_messages enable row level security;
-- No policies: reached through the functions below only.

-- ------------------------------------------------ small helpers

-- The visitor's connection, as a one-way code (never the address).
create or replace function public.site_chat_ip_hash()
returns text language plpgsql stable security definer set search_path = public as $$
declare
  ip inet;
begin
  begin
    ip := public.request_ip();
  exception when others then
    ip := null;
  end;
  if ip is null then return null; end if;
  return md5('nw-chat:' || host(ip));
end $$;
revoke all on function public.site_chat_ip_hash() from public, anon, authenticated;

-- The founders' phones; tapping the notice opens the website chats.
create or replace function public.site_chat_notify(p_title text, p_message text)
returns void language plpgsql security definer set search_path = public as $$
declare
  topic text;
begin
  select substring(p.prosrc from '''topic'',\s*''([^'']+)''') into topic
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notify_phone'
   limit 1;
  if topic is null then
    perform public.notify_phone(p_title, p_message, 'speech_balloon');
    return;
  end if;
  perform net.http_post(
    url := 'https://ntfy.sh',
    body := jsonb_build_object(
      'topic', topic,
      'title', p_title,
      'message', p_message,
      'tags', array['speech_balloon'],
      'click', 'https://nomadmaps.io/chats/#site'),
    headers := '{"Content-Type": "application/json"}'::jsonb);
exception when others then
  null; -- a notice never gets in the way of the chat
end $$;
revoke all on function public.site_chat_notify(text, text) from public, anon, authenticated;

-- One space, as one line for the assistant.
create or replace function public.site_chat_venue_line(v public.venues, p_area text default null)
returns text language plpgsql stable set search_path = public as $$
declare
  g     jsonb := coalesce(v.g_details, '{}'::jsonb);
  hours text;
  facts text;
  rating numeric;
begin
  select string_agg(h, '; ') into hours
    from jsonb_array_elements_text(
           case when jsonb_typeof(coalesce(g -> 'regularOpeningHours', g -> 'currentOpeningHours') -> 'weekdayDescriptions') = 'array'
                then coalesce(g -> 'regularOpeningHours', g -> 'currentOpeningHours') -> 'weekdayDescriptions'
                else '[]'::jsonb end) h;
  facts := array_to_string(array_remove(array[
    case when v.power_outlets then 'plug sockets' end,
    case when v.aircon then 'aircon' end,
    case when v.comfortable_seating then 'comfortable seating' end,
    case when v.office_chairs then 'office chairs' end,
    case when v.quiet_space then 'quiet space' end,
    case when v.good_for_calls then 'good for calls' end,
    case when v.call_room then 'call room or booth' end,
    case when v.monitor then 'monitors' end,
    case when v.access_24h then '24-hour access' end,
    case when v.cozy then 'cozy' end,
    case when v.serves_food then 'serves food' end,
    case when v.laptops_allowed is false then 'laptops not always welcome' end
  ], null), ', ');
  rating := coalesce(nullif(g ->> 'rating', '')::numeric, v.google_rating_snapshot);
  return concat_ws(' | ',
    v.name || ' (' || public.space_kind(v.type) || ')',
    nullif(concat_ws(', ', nullif(btrim(coalesce(p_area, v.neighbourhood, '')), ''), nullif(btrim(coalesce(v.city, '')), '')), ''),
    case when coalesce(v.wifi_speed_mbps, 0) > 0 then 'WiFi about ' || round(v.wifi_speed_mbps) || ' Mbps' end,
    case when rating is not null then 'Google rating ' || rating end,
    nullif(facts, ''),
    case when hours is not null then 'hours: ' || hours end,
    case when v.listing_tier = 'verified' then 'Verified listing (its page has a Send an enquiry button)' end,
    case when v.webflow_slug is not null then 'page: https://www.nomadwise.io/coworking/' || v.webflow_slug end);
exception when others then
  return v.name;
end $$;
revoke all on function public.site_chat_venue_line(public.venues, text) from public, anon, authenticated;

-- Spaces live on the site in one Region (a Location's first), as lines.
create or replace function public.site_chat_region_lines(
  p_region text, p_location text default null, p_limit integer default 30)
returns text language sql stable security definer set search_path = public as $$
  select string_agg(public.site_chat_venue_line(t.v, t.area), E'\n' order by t.o1, t.o2 desc nulls last)
    from (select v, l.name as area,
                 case when p_location is not null and v.webflow_location_id = p_location then 0 else 1 end as o1,
                 coalesce(v.google_rating_snapshot, 0) as o2
            from public.venues v
            left join public.webflow_locations l on l.id = v.webflow_location_id
           where v.webflow_region_id = p_region
             and v.website_status = 'released'
             and v.webflow_slug is not null
             and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
           order by 3, 4 desc nulls last
           limit greatest(1, least(coalesce(p_limit, 30), 40))) t;
$$;
revoke all on function public.site_chat_region_lines(text, text, integer) from public, anon, authenticated;

-- What the page the visitor is on is about, and any Region they name.
create or replace function public.site_chat_context(p_chat uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  c        public.site_chats%rowtype;
  path     text;
  s1       text;
  s2       text;
  v        public.venues%rowtype;
  reg      record;
  loc      record;
  ctry     record;
  rid      text;
  lid      text;
  out      text := '';
  lines    text;
  lastmsg  text;
  r        record;
  extra    integer := 0;
begin
  select * into c from public.site_chats where id = p_chat;
  path := lower(regexp_replace(coalesce(c.page_url, ''), '^https?://[^/]+', ''));
  path := split_part(split_part(path, '?', 1), '#', 1);
  s1 := split_part(path, '/', 2);
  s2 := split_part(path, '/', 3);
  if s1 = 'de' then
    s1 := split_part(path, '/', 3);
    s2 := split_part(path, '/', 4);
  end if;

  out := 'The visitor is on this page: ' || coalesce(nullif(c.page_url, ''), 'unknown')
         || coalesce(' ("' || nullif(c.page_title, '') || '")', '') || E'\n';

  if s1 = 'coworking' and s2 <> '' then
    select * into v from public.venues x where x.webflow_slug = s2 limit 1;
    if v.id is not null then
      out := out || E'\nThis page is about one place:\n' || public.site_chat_venue_line(v)
             || E'\nClaim link for this place (free, for the people who run it): https://nomadmaps.io/?claim='
             || s2 || E'\n'
             || case when coalesce(v.listing_owner_email, '') <> ''
                     then 'This place has already been claimed by its owner.' || E'\n' else '' end;
      rid := v.webflow_region_id;
      lid := v.webflow_location_id;
    end if;
  elsif s1 = 'region' and s2 <> '' then
    select id into rid from public.webflow_regions where slug = s2 limit 1;
  elsif s1 = 'locations' and s2 <> '' then
    select id, region_id into lid, rid from public.webflow_locations where slug = s2 limit 1;
  elsif s1 = 'country' and s2 <> '' then
    select id, name into ctry from public.webflow_countries where slug = s2 limit 1;
    if ctry.id is not null then
      select string_agg('- ' || r2.name || ': https://www.nomadwise.io/region/' || r2.slug, E'\n' order by r2.name)
        into lines
        from (select * from public.webflow_regions g
               where lower(btrim(coalesce(g.country, ''))) = lower(btrim(ctry.name))
                 and g.slug is not null
               order by g.name limit 40) r2;
      out := out || E'\nThis page is about ' || ctry.name || '. Its city and area pages on Nomadwise:' || E'\n'
             || coalesce(lines, '(none listed)') || E'\n';
    end if;
  end if;

  if rid is not null then
    select name, slug, country into reg from public.webflow_regions where id = rid;
    lines := public.site_chat_region_lines(rid, lid, 30);
    out := out || E'\nPlaces listed on Nomadwise in ' || coalesce(reg.name, 'this area')
           || coalesce(', ' || reg.country, '')
           || coalesce(' (city page: https://www.nomadwise.io/region/' || reg.slug || ')', '') || E':\n'
           || coalesce(lines, '(none yet)') || E'\n';
  end if;

  -- A Region the visitor names (up to two), with its places.
  select body into lastmsg from public.site_chat_messages
   where chat_id = p_chat and role = 'visitor' order by id desc limit 1;
  if coalesce(lastmsg, '') <> '' then
    for r in
      select g.id, g.name, g.slug, g.country
        from public.webflow_regions g
       where g.id is distinct from rid
         and char_length(btrim(split_part(g.name, ',', 1))) >= 4
         and position(lower(btrim(split_part(g.name, ',', 1))) in lower(lastmsg)) > 0
       order by char_length(g.name) desc
       limit 2
    loop
      lines := public.site_chat_region_lines(r.id, null, 15);
      out := out || E'\nPlaces listed on Nomadwise in ' || r.name || coalesce(', ' || r.country, '')
             || ' (city page: https://www.nomadwise.io/region/' || coalesce(r.slug, '') || E'):\n'
             || coalesce(lines, '(none yet)') || E'\n';
      extra := extra + 1;
    end loop;
  end if;

  return out;
exception when others then
  return coalesce(out, '');
end $$;
revoke all on function public.site_chat_context(uuid) from public, anon, authenticated;

-- The assistant's standing instructions.
create or replace function public.site_chat_instructions()
returns text language sql immutable as $$
  select concat_ws(E'\n',
'You are the chat assistant on nomadwise.io, writing for Nomadwise in a chat box on the website.',
'',
'About Nomadwise:',
'- Nomadwise.io is a guide to work-friendly cafes and coworking spaces for remote workers and digital nomads: around 1,000 places in many countries. Each page shows what matters for working there: WiFi speed, plug sockets, opening hours, quiet space, calls and more. Using the site is free. It also has travel guides (eSIMs, VPNs and insurance for nomads).',
'- Nomadwise does not take bookings or payments for desks, day passes or meeting rooms, and cannot see availability. To book, people contact the place directly: its website, phone, or the Send an enquiry button that Verified pages have.',
'- Anyone can suggest a correction or a tag with "Something need updating?" or "Add a tag" on a place''s page, or simply tell you here.',
'',
'For people who run a cafe or coworking space:',
'- Being listed on Nomadwise is free. They can claim their page for free: on the place''s page press "Claim this listing for free", or go to https://nomadmaps.io/?claim (and search for their space). Use the exact claim link given below when you have one.',
'- After claiming they have their own Owner account, where they update opening hours and contact details and add their own photos, description and prices. A person checks each change before it goes live.',
'- There is an optional Verified listing for extra visibility (it adds the Send an enquiry button). The details and price are in the Owner account; never quote a price yourself.',
'- If their space is not on Nomadwise yet, ask for its name, the city, its website or Instagram, and their email, and say Jonathan from the team will look at adding it. That needs a person.',
'',
'How to write:',
'- Sound like a friendly, knowledgeable person from an established company: warm, natural and brief. Usually one to three short sentences, never more than about 90 words. Plain text only: no markdown, no headings, no bold. A short list of up to three places is fine, one per line.',
'- Answer in the language the visitor writes in. Otherwise British English.',
'- Never use the long dash character. Never promise a time ("within 24 hours", "today"). Do not oversell.',
'- Only use facts given here or on the page information below. Never invent a place, a price, opening hours or a feature. If you do not know, say so and offer that Jonathan from the team can find out by email.',
'- When you suggest places, give each name with its full page link.',
'- Ask at most one question in a reply.',
'- You are an automated assistant for Nomadwise, not a person. Do not pretend to be one. If someone asks, say so plainly, and that Jonathan, a cofounder, reads every chat and can reply himself. Never name the AI model or the company that made it.',
'- A person from the team is needed when: they ask for a person; they report something wrong on a page; it is a complaint, a partnership, press or business question; their space is not listed yet; or you cannot help. Then say Jonathan will pick it up, and if you do not have their email yet, ask for it.',
'',
'Answer with this JSON and nothing else:',
'{"reply": "your message to the visitor", "who": "owner" if they run a space, "visitor" if they are looking for places, or "unknown", "needs_person": true or false, "email": "their email address if they gave one in this chat, else empty"}');
$$;

-- ------------------------------------------------ the assistant

-- Sends the conversation to Claude, unless an answer is already coming.
create or replace function public.site_chat_ask(p_chat uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  c      public.site_chats%rowtype;
  k      text;
  model  text;
  msgs   jsonb := '[]'::jsonb;
  m      record;
  r_role text;
  txt    text;
  cur_role text;
  cur_txt  text;
  upto   bigint;
  req    bigint;
begin
  select * into c from public.site_chats where id = p_chat for update;
  if c.id is null or c.mode <> 'bot' or c.status <> 'open' then return; end if;
  if c.pending_req is not null and c.pending_since > now() - interval '90 seconds' then
    return;
  end if;

  select decrypted_secret into k
    from vault.decrypted_secrets where name = 'anthropic_api_key' limit 1;
  select nullif(btrim(decrypted_secret), '') into model
    from vault.decrypted_secrets where name = 'anthropic_model' limit 1;
  model := coalesce(model, 'claude-sonnet-4-5');

  -- The last 24 messages, as alternating turns (theirs = user).
  for m in
    select * from (select * from public.site_chat_messages
                    where chat_id = p_chat order by id desc limit 24) t
     order by id
  loop
    r_role := case when m.role = 'visitor' then 'user' else 'assistant' end;
    txt := case when m.role = 'team'
                then '(' || coalesce(m.author, 'Jonathan') || ' from the Nomadwise team wrote:) ' || m.body
                else m.body end;
    if cur_role is null then
      if r_role = 'assistant' then continue; end if; -- must start with theirs
      cur_role := r_role; cur_txt := txt;
    elsif r_role = cur_role then
      cur_txt := cur_txt || E'\n\n' || txt;
    else
      msgs := msgs || jsonb_build_array(jsonb_build_object('role', cur_role, 'content', cur_txt));
      cur_role := r_role; cur_txt := txt;
    end if;
    if m.role = 'visitor' then upto := m.id; end if;
  end loop;
  if cur_role is null or cur_role <> 'user' then return; end if; -- nothing new of theirs
  msgs := msgs || jsonb_build_array(jsonb_build_object('role', cur_role, 'content', cur_txt));

  if nullif(btrim(coalesce(k, '')), '') is null then
    update public.site_chats set needs_team = true where id = p_chat;
    return;
  end if;

  select net.http_post(
    url := 'https://api.anthropic.com/v1/messages',
    body := jsonb_build_object(
      'model', model,
      'max_tokens', 400,
      'system', public.site_chat_instructions() || E'\n\nToday is '
                || to_char(now(), 'FMDay DD Month YYYY') || E'.\n\n'
                || public.site_chat_context(p_chat),
      'messages', msgs),
    headers := jsonb_build_object(
      'x-api-key', k,
      'anthropic-version', '2023-06-01',
      'content-type', 'application/json'),
    timeout_milliseconds := 60000)
  into req;

  update public.site_chats
     set pending_req = req, pending_upto = upto, pending_since = now()
   where id = p_chat;
end $$;
revoke all on function public.site_chat_ask(uuid) from public, anon, authenticated;

-- Past a limit, or without a key: a kind holding message, once.
create or replace function public.site_chat_hold(p_chat uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.site_chats%rowtype;
begin
  select * into c from public.site_chats where id = p_chat;
  if c.id is null then return; end if;
  if not exists (select 1 from public.site_chat_messages
                  where chat_id = p_chat and role = 'bot' and author = 'hold') then
    insert into public.site_chat_messages (chat_id, role, author, body)
    values (p_chat, 'bot', 'hold',
            case when coalesce(c.visitor_email, '') = ''
                 then 'Thanks for your message. Jonathan from our team will read it and reply. What is the best email address to reach you on?'
                 else 'Thanks for your message. Jonathan from our team will read it and reply to you by email.' end);
  end if;
  update public.site_chats set needs_team = true, last_at = now() where id = p_chat;
end $$;
revoke all on function public.site_chat_hold(uuid) from public, anon, authenticated;

-- Reads Claude's answer when it has come, and keeps it.
create or replace function public.site_chat_settle(p_chat uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  c      public.site_chats%rowtype;
  resp   record;
  rbody  jsonb;
  txt    text;
  parsed jsonb;
  reply  text;
  em     text;
  newer  boolean;
begin
  select * into c from public.site_chats where id = p_chat for update;
  if c.id is null or c.pending_req is null then return; end if;

  select r.status_code, r.content, r.timed_out into resp
    from net._http_response r where r.id = c.pending_req;
  if not found then
    if c.pending_since > now() - interval '90 seconds' then return; end if;
    update public.site_chats set pending_req = null, pending_since = null where id = p_chat;
    perform public.site_chat_hold(p_chat);
    return;
  end if;

  update public.site_chats set pending_req = null, pending_since = null where id = p_chat;

  if coalesce(resp.timed_out, false) or resp.status_code is distinct from 200 then
    perform public.site_chat_hold(p_chat);
    return;
  end if;

  begin
    rbody := resp.content::jsonb;
    select string_agg(x ->> 'text', E'\n') into txt
      from jsonb_array_elements(rbody -> 'content') x
     where x ->> 'type' = 'text';
  exception when others then
    txt := null;
  end;
  begin
    parsed := substring(txt from '\{.*\}')::jsonb;
  exception when others then
    parsed := null;
  end;
  reply := btrim(coalesce(parsed ->> 'reply', txt, ''));
  reply := regexp_replace(reply, '\s*' || chr(8212) || '\s*', ', ', 'g');
  reply := replace(reply, chr(8211), '-');
  if reply = '' then
    perform public.site_chat_hold(p_chat);
    return;
  end if;

  -- Only if the chat is still the assistant's (a founder may have
  -- taken it over while the answer was on its way).
  if (select mode from public.site_chats where id = p_chat) = 'bot' then
    insert into public.site_chat_messages (chat_id, role, author, body)
    values (p_chat, 'bot', 'Assistant', left(reply, 4000));
    em := lower(btrim(coalesce(parsed ->> 'email', '')));
    update public.site_chats
       set bot_replies = bot_replies + 1,
           last_at = now(),
           who = coalesce(case when parsed ->> 'who' in ('owner', 'visitor') then parsed ->> 'who' end, who),
           visitor_email = coalesce(visitor_email,
                             case when em ~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then left(em, 200) end)
     where id = p_chat;
    if lower(coalesce(parsed ->> 'needs_person', '')) = 'true' and not c.needs_team then
      update public.site_chats set needs_team = true where id = p_chat;
      perform public.site_chat_notify('A chat needs you',
        left(coalesce((select body from public.site_chat_messages
                        where chat_id = p_chat and role = 'visitor' order by id desc limit 1), ''), 140));
    end if;
  end if;

  -- They wrote again while the answer was on its way: answer that too.
  select exists (select 1 from public.site_chat_messages
                  where chat_id = p_chat and role = 'visitor' and id > coalesce(c.pending_upto, 0))
    into newer;
  if newer then
    perform public.site_chat_ask(p_chat);
  end if;
exception when others then
  begin
    update public.site_chats set pending_req = null, pending_since = null where id = p_chat;
  exception when others then null; end;
end $$;
revoke all on function public.site_chat_settle(uuid) from public, anon, authenticated;

-- ------------------------------------------------ the visitor's side

-- What the chat box shows: the messages after p_after, who is
-- answering, and whether an answer is coming.
create or replace function public.site_chat_view(p_chat uuid, p_after bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'mode', c.mode,
    'typing', c.pending_req is not null,
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id,
               'role', m.role,
               'author', case when m.role = 'team' then coalesce(m.author, 'Jonathan') || ' from Nomadwise'
                              when m.role = 'bot' then 'Nomadwise' else null end,
               'body', m.body,
               'at', m.at) order by m.id)
        from (select * from public.site_chat_messages x
               where x.chat_id = c.id and x.id > coalesce(p_after, 0)
               order by x.id limit 200) m), '[]'::jsonb))
    from public.site_chats c where c.id = p_chat;
$$;
revoke all on function public.site_chat_view(uuid, bigint) from public, anon, authenticated;

-- True when the assistant must not answer this one (a limit is
-- reached). An overall limit tells the phones, once a day.
create or replace function public.site_chat_over_limit(p_chat uuid, p_ip text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  day_n   integer;
  month_n integer;
  kind    text;
begin
  if (select bot_replies from public.site_chats where id = p_chat) >= 12 then
    return true;
  end if;
  if p_ip is not null and (select count(*) from public.site_chat_messages m
                             join public.site_chats s on s.id = m.chat_id
                            where s.ip_hash = p_ip and m.role = 'bot' and m.author = 'Assistant'
                              and m.at > now() - interval '1 day') >= 20 then
    return true;
  end if;
  select count(*) filter (where at > now() - interval '1 day'),
         count(*) filter (where at >= date_trunc('month', now()))
    into day_n, month_n
    from public.site_chat_messages
   where role = 'bot' and author = 'Assistant'
     and at >= least(now() - interval '1 day', date_trunc('month', now()));
  kind := case when month_n >= 1000 then 'month'
               when day_n >= 60 then 'day' end;
  if kind is null then return false; end if;
  insert into public.site_chat_alerts (day, kind) values (current_date, kind)
  on conflict do nothing;
  if found then
    perform public.site_chat_notify('Chat assistant paused',
      case when kind = 'month'
           then 'It has answered 1,000 times this month, so new chats wait for you until the 1st.'
           else 'It has answered 60 times today, so new chats wait for you until tomorrow.' end);
  end if;
  return true;
end $$;
revoke all on function public.site_chat_over_limit(uuid, text) from public, anon, authenticated;

create or replace function public.site_chat_send(
  p_token uuid, p_body text, p_page text default null, p_title text default null,
  p_after bigint default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  msg   text := btrim(coalesce(p_body, ''));
  iph   text := public.site_chat_ip_hash();
  c     public.site_chats%rowtype;
  first boolean := false;
  em    text;
  vid   uuid;
  slug  text;
begin
  if coalesce(public.visit_blocked(), false) then
    raise exception 'The chat is not available right now.';
  end if;
  if p_token is null then raise exception 'Missing chat key.'; end if;
  if msg = '' then raise exception 'Write a message first.'; end if;
  msg := left(msg, 800);

  if iph is not null and (
       (select count(*) from public.site_chat_messages
         where ip_hash = iph and role = 'visitor'
           and at > now() - interval '1 hour') >= 15
    or (select count(*) from public.site_chat_messages
         where ip_hash = iph and role = 'visitor'
           and at > now() - interval '1 day') >= 40) then
    raise exception 'That is a lot of messages. Please try again a little later, or email hello@nomadwise.io.';
  end if;

  select * into c from public.site_chats where token = p_token for update;
  if c.id is not null then
    -- one message every 3 seconds; the same words twice in a row once
    if exists (select 1 from public.site_chat_messages
                where chat_id = c.id and role = 'visitor'
                  and at > now() - interval '3 seconds') then
      raise exception 'One moment, please.';
    end if;
    if (select body from public.site_chat_messages
         where chat_id = c.id and role = 'visitor' order by id desc limit 1) = msg then
      return public.site_chat_view(c.id, p_after);
    end if;
  end if;
  if c.id is null then
    if (iph is not null and (select count(*) from public.site_chats
                              where ip_hash = iph and started_at > now() - interval '1 day') >= 3)
       or (select count(*) from public.site_chats where started_at > now() - interval '1 hour') >= 20
       or (select count(*) from public.site_chats where started_at > now() - interval '1 day') >= 80 then
      raise exception 'The chat is busy right now. Please email hello@nomadwise.io.';
    end if;
    slug := nullif(split_part(split_part(split_part(lower(coalesce(p_page, '')), '/coworking/', 2), '?', 1), '#', 1), '');
    if slug is not null then
      select id into vid from public.venues where webflow_slug = slug limit 1;
    end if;
    insert into public.site_chats (token, page_url, page_title, first_page, ip_hash, venue_id)
    values (p_token, left(p_page, 500), left(p_title, 200), left(p_page, 500), iph, vid)
    returning * into c;
    first := true;
  end if;

  em := substring(msg from '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})');
  insert into public.site_chat_messages (chat_id, role, body, ip_hash)
  values (c.id, 'visitor', msg, iph);
  update public.site_chats
     set last_at = now(), last_seen_at = now(),
         page_url = coalesce(left(p_page, 500), page_url),
         page_title = coalesce(left(p_title, 200), page_title),
         visitor_msgs = visitor_msgs + 1,
         visitor_email = coalesce(visitor_email, lower(left(em, 200))),
         status = 'open', done_at = null
   where id = c.id
  returning * into c;

  if first then
    perform public.site_chat_notify('New chat on nomadwise.io',
      left(msg, 140) || coalesce(' (' || nullif(left(p_title, 60), '') || ')', ''));
  elsif c.mode = 'team' or c.needs_team then
    perform public.site_chat_notify('They wrote in a chat', left(msg, 140));
  end if;

  if c.mode = 'bot' then
    if public.site_chat_over_limit(c.id, iph) then
      perform public.site_chat_hold(c.id);
    else
      begin
        perform public.site_chat_ask(c.id);
      exception when others then
        perform public.site_chat_hold(c.id);
      end;
    end if;
  end if;

  return public.site_chat_view(c.id, p_after);
end $$;
revoke all on function public.site_chat_send(uuid, text, text, text, bigint) from public;
grant execute on function public.site_chat_send(uuid, text, text, text, bigint) to anon, authenticated;

create or replace function public.site_chat_poll(p_token uuid, p_after bigint default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cid uuid;
begin
  if p_token is null then return null; end if;
  select id into cid from public.site_chats where token = p_token;
  if cid is null then return null; end if;
  perform public.site_chat_settle(cid);
  update public.site_chats set last_seen_at = now() where id = cid;
  -- what we wrote is seen once it reaches their screen
  update public.site_chat_messages set read_at = now()
   where chat_id = cid and role = 'team' and read_at is null and id > coalesce(p_after, 0);
  return public.site_chat_view(cid, p_after);
end $$;
revoke all on function public.site_chat_poll(uuid, bigint) from public;
grant execute on function public.site_chat_poll(uuid, bigint) to anon, authenticated;

-- ------------------------------------------------ the founders' side

create or replace function public.admin_site_chats(p_done boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'founders only'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(t)::jsonb order by t.waiting desc, t.last_at desc)
      from (select c.id, c.started_at, c.last_at, c.last_seen_at,
                   c.last_seen_at > now() - interval '45 seconds' as here,
                   c.page_url, c.page_title, c.visitor_name, c.visitor_email,
                   c.who, c.mode, c.needs_team, c.status,
                   v.name as space_name,
                   lm.body as last_body, lm.role as last_role,
                   (select count(*) from public.site_chat_messages m
                     where m.chat_id = c.id and m.role = 'visitor'
                       and m.at > coalesce(c.team_seen_at, 'epoch'::timestamptz)) as unread,
                   (select count(*) from public.site_chat_messages m where m.chat_id = c.id) as messages,
                   (c.status = 'open' and (c.needs_team or (c.mode = 'team' and lm.role = 'visitor'))) as waiting
              from public.site_chats c
              left join public.venues v on v.id = c.venue_id
              left join lateral (select body, role from public.site_chat_messages m
                                  where m.chat_id = c.id order by m.id desc limit 1) lm on true
             where case when p_done then c.status = 'done'
                        else c.status = 'open' end
             order by c.last_at desc
             limit 200) t), '[]'::jsonb);
end $$;
revoke all on function public.admin_site_chats(boolean) from public, anon;
grant execute on function public.admin_site_chats(boolean) to authenticated;

-- The number on the Website tab: chats waiting for a founder.
create or replace function public.admin_site_chats_waiting()
returns integer language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then return 0; end if;
  return (select count(*) from public.site_chats c
           where c.status = 'open'
             and (c.needs_team
                  or (c.mode = 'team' and (select m.role from public.site_chat_messages m
                                            where m.chat_id = c.id order by m.id desc limit 1) = 'visitor')));
end $$;
revoke all on function public.admin_site_chats_waiting() from public, anon;
grant execute on function public.admin_site_chats_waiting() to authenticated;

-- One chat, in the shape the chat thread on the Chats screen uses.
create or replace function public.admin_site_chat(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'founders only'; end if;
  perform public.site_chat_settle(p_id);
  update public.site_chats set team_seen_at = now() where id = p_id;
  return (select jsonb_build_object(
      'chat', jsonb_build_object(
         'id', c.id, 'mode', c.mode, 'status', c.status, 'needs_team', c.needs_team,
         'who', c.who, 'visitor_email', c.visitor_email, 'visitor_name', c.visitor_name,
         'page_url', c.page_url, 'page_title', c.page_title, 'first_page', c.first_page,
         'started_at', c.started_at, 'last_seen_at', c.last_seen_at,
         'here', c.last_seen_at > now() - interval '45 seconds',
         'typing', c.pending_req is not null, 'note', c.note),
      'messages', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'id', m.id,
                  'team', m.role <> 'visitor',
                  'author', case when m.role = 'bot' then 'Assistant'
                                 when m.role = 'team' then coalesce(m.author, 'Jonathan')
                                 else coalesce(c.visitor_name, 'Visitor') end,
                  'role', m.role,
                  'body', m.body,
                  'at', m.at,
                  'read', m.read_at is not null,
                  'emailed', m.emailed_at is not null) order by m.id)
           from (select * from public.site_chat_messages x
                  where x.chat_id = c.id order by x.id desc limit 400) m), '[]'::jsonb))
    from public.site_chats c where c.id = p_id);
end $$;
revoke all on function public.admin_site_chat(uuid) from public, anon;
grant execute on function public.admin_site_chat(uuid) to authenticated;

-- A founder writes: the chat is theirs from now on (the assistant
-- stops); the visitor sees it live, or is emailed it if they left.
create or replace function public.admin_site_chat_send(p_id uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  msg text := btrim(coalesce(p_body, ''));
begin
  if not coalesce(public.is_admin(), false) then raise exception 'founders only'; end if;
  if msg = '' then raise exception 'Write a message first.'; end if;
  insert into public.site_chat_messages (chat_id, role, author, body)
  values (p_id, 'team', coalesce(public.chat_team_name(), 'Jonathan'), left(msg, 4000));
  update public.site_chats
     set mode = 'team', needs_team = false, last_at = now(), team_seen_at = now(),
         pending_req = null, pending_since = null
   where id = p_id;
  return public.admin_site_chat(p_id);
end $$;
revoke all on function public.admin_site_chat_send(uuid, text) from public, anon;
grant execute on function public.admin_site_chat_send(uuid, text) to authenticated;

-- Take over / hand back, done / reopen, and their email or name by hand.
create or replace function public.admin_site_chat_set(
  p_id uuid, p_mode text default null, p_status text default null,
  p_email text default null, p_name text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'founders only'; end if;
  if p_mode is not null and p_mode not in ('bot', 'team') then raise exception 'Unknown mode.'; end if;
  if p_status is not null and p_status not in ('open', 'done') then raise exception 'Unknown status.'; end if;
  update public.site_chats
     set mode = coalesce(p_mode, mode),
         needs_team = case when p_mode is not null or p_status = 'done' then false else needs_team end,
         status = coalesce(p_status, status),
         done_at = case when p_status = 'done' then now()
                        when p_status = 'open' then null else done_at end,
         visitor_email = case when p_email is null then visitor_email
                              else nullif(lower(left(btrim(p_email), 200)), '') end,
         visitor_name = case when p_name is null then visitor_name
                             else nullif(left(btrim(p_name), 120), '') end,
         note = case when p_note is null then note else nullif(left(btrim(p_note), 1000), '') end
   where id = p_id;
  return public.admin_site_chat(p_id);
end $$;
revoke all on function public.admin_site_chat_set(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.admin_site_chat_set(uuid, text, text, text, text, text) to authenticated;

-- ------------------------------------------------ email when they left

-- Every two minutes: what a founder wrote that the visitor has not
-- seen, a minute after the last of it, emailed to them once, if they
-- gave an address and are not on the site.
create or replace function public.site_chat_email_sync()
returns void language plpgsql security definer set search_path = public as $$
declare
  c     record;
  words text;
  asked text;
  who   text;
begin
  for c in
    select s.* from public.site_chats s
     where coalesce(s.visitor_email, '') <> ''
       and (s.last_seen_at is null or s.last_seen_at < now() - interval '2 minutes')
       and exists (select 1 from public.site_chat_messages m
                    where m.chat_id = s.id and m.role = 'team'
                      and m.read_at is null and m.emailed_at is null)
       and not exists (select 1 from public.site_chat_messages m
                        where m.chat_id = s.id and m.role = 'team'
                          and m.read_at is null and m.emailed_at is null
                          and m.at > now() - interval '1 minute')
     limit 20
  loop
    select string_agg(m.body, E'\n\n' order by m.id), max(m.author) into words, who
      from public.site_chat_messages m
     where m.chat_id = c.id and m.role = 'team' and m.read_at is null and m.emailed_at is null;
    select body into asked from public.site_chat_messages
     where chat_id = c.id and role = 'visitor' order by id desc limit 1;
    perform public.send_owner_email(
      c.visitor_email,
      'Your chat with Nomadwise',
      'Hi' || coalesce(' ' || split_part(nullif(btrim(c.visitor_name), ''), ' ', 1), '') || ',' || E'\n\n'
        || 'You wrote to us in the chat on nomadwise.io:' || E'\n'
        || '"' || left(coalesce(asked, ''), 400) || '"' || E'\n\n'
        || words || E'\n\n'
        || 'Just reply to this email if there is anything else.' || E'\n\n'
        || 'Kind regards,' || E'\n' || coalesce(who, 'Jonathan') || E'\n' || 'Nomadwise.io',
      'site_chat', c.id::text, null, null);
    update public.site_chat_messages set emailed_at = now()
     where chat_id = c.id and role = 'team' and read_at is null and emailed_at is null;
  end loop;
end $$;
revoke all on function public.site_chat_email_sync() from public, anon, authenticated;
grant execute on function public.site_chat_email_sync() to service_role;

do $$
begin
  perform cron.unschedule('site-chat-email-sync');
exception when others then null;
end $$;
select cron.schedule('site-chat-email-sync', '*/2 * * * *',
  'select public.site_chat_email_sync()');
