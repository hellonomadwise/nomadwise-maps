-- ============================================================
-- Migration 200: the website chat asks for the best way to reach
-- someone: an email address, or a WhatsApp or phone number.
--
-- Jonathan, 22 Oct 2026, on a test chat ("give me a human"): the
-- assistant asked only for an email. Many people would rather give a
-- WhatsApp number, or another way. Now:
--   * The assistant asks "the best way to reach you: an email
--     address, or a WhatsApp or phone number", accepts either, and
--     hands back the number as well as any email (new "phone" field).
--   * The holding message (when the assistant is not answering) asks
--     the same way.
--   * site_chats.visitor_phone keeps the number; Chats shows it with
--     an Open WhatsApp button, and it can be added or changed by hand.
--   * Replies are still emailed when they gave an email and left the
--     site. A number only: Jonathan answers on WhatsApp himself.
--
-- Copies of migration 190's and 192's functions with only these
-- changes. Pure ASCII. Safe to apply twice.
-- ============================================================

alter table public.site_chats add column if not exists visitor_phone text;

drop function if exists public.admin_site_chat_set(uuid, text, text, text, text, text);

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
'- If their space is not on Nomadwise yet, ask for its name, the city, its website or Instagram, and the best way to reach them, and say Jonathan from the team will look at adding it. That needs a person.',
'',
'How to write:',
'- Sound like a friendly, knowledgeable person from an established company: warm, natural and brief. Usually one to three short sentences, never more than about 90 words. Plain text only: no markdown, no headings, no bold. A short list of up to three places is fine, one per line.',
'- Answer in the language the visitor writes in. Otherwise British English.',
'- Never use the long dash character. Never promise a time ("within 24 hours", "today"). Do not oversell.',
'- Only use facts given here or on the page information below. Never invent a place, a price, opening hours or a feature. If you do not know, say so and offer that Jonathan from the team can find out and get back to them.',
'- When you suggest places, give each name with its full page link.',
'- Ask at most one question in a reply.',
'- You are an automated assistant for Nomadwise, not a person. Do not pretend to be one. If someone asks, say so plainly, and that Jonathan, a cofounder, reads every chat and can reply himself. Never name the AI model or the company that made it.',
'- A person from the team is needed when: they ask for a person; they report something wrong on a page; it is a complaint, a partnership, press or business question; their space is not listed yet; or you cannot help. Then say Jonathan will pick it up, and if you do not have a way to reach them yet, ask for the best way to reach them: an email address, or a WhatsApp or phone number, whichever they prefer. Accept either; do not insist on email.',
'',
'Answer with this JSON and nothing else:',
'{"reply": "your message to the visitor", "who": "owner" if they run a space, "visitor" if they are looking for places, or "unknown", "needs_person": true or false, "email": "their email address if they gave one in this chat, else empty", "phone": "their WhatsApp or phone number if they gave one in this chat, with the country code if they gave it, else empty"}');
$$;

create or replace function public.site_chat_blog_rules()
returns text language sql immutable as $$
  select concat_ws(E'\n',
'How to help on this guide:',
'- Help them decide, so they can choose with confidence. Use the options this guide covers (in the page text above). In plain words, explain the difference that matters for them and say which fits what they told you: trip length, countries, how much data, budget, their phone or device. If you need to know more, ask one short question.',
'- You do not know current prices, data allowances or offers beyond what is in the page text. Never state a price or a discount. Say the current plans and prices are on the provider''s site, through the buttons in this guide (for example the summary near the top).',
'- Do not write provider web addresses. Point them to the buttons in this guide instead.',
'- Never say a VPN makes something legal or gets round any particular restriction.',
'- A problem with an order, a refund, an activation or an account is for the provider''s own support to sort out: say so kindly, and suggest they contact the provider.',
'- Do not bring up coworking spaces, cafes or listings unless they ask.',
'- If you are not sure, say so, and offer that Jonathan from the team can get back to them (by email or WhatsApp, whichever they prefer).');
$$;

-- What the page is about (a copy of migration 190's, with the blog branch).

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
            case when coalesce(c.visitor_email, '') = '' and coalesce(c.visitor_phone, '') = ''
                 then 'Thanks for your message. Jonathan from our team will read it and reply. '
                      || 'What is the best way to reach you: an email address, or a WhatsApp number?'
                 when coalesce(c.visitor_email, '') <> ''
                 then 'Thanks for your message. Jonathan from our team will read it and reply to you by email.'
                 else 'Thanks for your message. Jonathan from our team will read it and get back to you.' end);
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
  ph     text;
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
    ph := btrim(regexp_replace(coalesce(parsed ->> 'phone', ''), '[^0-9+() -]', '', 'g'));
    if length(regexp_replace(ph, '[^0-9]', '', 'g')) < 7 then ph := null; end if;
    update public.site_chats
       set bot_replies = bot_replies + 1,
           last_at = now(),
           who = coalesce(case when parsed ->> 'who' in ('owner', 'visitor') then parsed ->> 'who' end, who),
           visitor_email = coalesce(visitor_email,
                             case when em ~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then left(em, 200) end),
           visitor_phone = coalesce(visitor_phone, left(ph, 40))
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

create or replace function public.admin_site_chats(p_done boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'founders only'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(t)::jsonb order by t.waiting desc, t.last_at desc)
      from (select c.id, c.started_at, c.last_at, c.last_seen_at,
                   c.last_seen_at > now() - interval '45 seconds' as here,
                   c.page_url, c.page_title, c.visitor_name, c.visitor_email, c.visitor_phone,
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

create or replace function public.admin_site_chat(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'founders only'; end if;
  perform public.site_chat_settle(p_id);
  update public.site_chats set team_seen_at = now() where id = p_id;
  return (select jsonb_build_object(
      'chat', jsonb_build_object(
         'id', c.id, 'mode', c.mode, 'status', c.status, 'needs_team', c.needs_team,
         'who', c.who, 'visitor_email', c.visitor_email, 'visitor_phone', c.visitor_phone,
         'visitor_name', c.visitor_name,
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

create or replace function public.admin_site_chat_set(
  p_id uuid, p_mode text default null, p_status text default null,
  p_email text default null, p_name text default null, p_note text default null,
  p_phone text default null)
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
         visitor_phone = case when p_phone is null then visitor_phone
                              else nullif(left(btrim(regexp_replace(p_phone, '[^0-9+() -]', '', 'g')), 40), '') end,
         visitor_name = case when p_name is null then visitor_name
                             else nullif(left(btrim(p_name), 120), '') end,
         note = case when p_note is null then note else nullif(left(btrim(p_note), 1000), '') end
   where id = p_id;
  return public.admin_site_chat(p_id);
end $$;
revoke all on function public.admin_site_chat_set(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.admin_site_chat_set(uuid, text, text, text, text, text, text) to authenticated;

notify pgrst, 'reload schema';
