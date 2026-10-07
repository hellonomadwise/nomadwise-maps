-- Migration 161: a chat between a space's owner and Nomadwise.
--
-- Jonathan, 7 Oct 2026, with a tour operator's chat in another app as
-- the picture: an open channel inside the Owner account ("Inbox &
-- support", with a number when something is unread), a list of the
-- chats for him on his phone, a notice when somebody writes, and a
-- record of what was said. For spaces that do not use WhatsApp, and
-- as the place where an owner can simply ask.
--
-- One chat per space. The owner writes from their Owner account; a
-- founder answers from the Chats screen (nomadmaps.io/chats), and can
-- write first to any space that has an owner. His choices: the owner
-- is emailed what we wrote ("Yes, email them"), our messages are
-- signed with the founder's first name ("Jonathan from Nomadwise"),
-- and either side can start.
--
--   space_chat_messages      every message, with the owner it was
--                            written with (a later owner of the same
--                            space starts with an empty chat and is
--                            never emailed the old one); read_at is when the other
--                            side opened the chat (the two ticks);
--                            emailed_at is when the owner was emailed
--   owner_chat(venue)        the owner's view; opening it marks our
--                            messages as read
--   owner_chat_send(...)     the owner writes; the founders' phones
--                            are told (chat_notify: tapping the
--                            notice opens the chats)
--   owner_chat_unread()      per space, how many of ours are unread
--   admin_chats()            every space with an owner, the ones
--                            waiting for an answer first
--   admin_chat(venue)        one chat; opening it marks theirs read
--   admin_chat_send(...)     a founder writes
--   admin_chats_unread()     the number beside "Chats" in the menu
--   chat_email_sync()        every two minutes: what we wrote and the owner
--                            has not seen is emailed to them, once,
--                            a minute after the last of it (several
--                            messages in a row make one email; none
--                            when they are reading along in the chat)
--
-- The table is reached through these functions only.

create table if not exists public.space_chat_messages (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues(id) on delete cascade,
  from_team    boolean not null,
  author       text,
  author_email text,
  body         text not null check (char_length(body) between 1 and 4000),
  at           timestamptz not null default now(),
  read_at      timestamptz,
  emailed_at   timestamptz
);
create index if not exists idx_space_chat_venue_at
  on public.space_chat_messages (venue_id, at);
create index if not exists idx_space_chat_to_email
  on public.space_chat_messages (venue_id)
  where from_team and emailed_at is null;
create index if not exists idx_space_chat_unread_theirs
  on public.space_chat_messages (venue_id)
  where not from_team and read_at is null;

alter table public.space_chat_messages enable row level security;

-- Which owner the chat was with when the message was written: a later
-- owner of the same space starts with an empty chat.
alter table public.space_chat_messages
  add column if not exists owner_email text;
update public.space_chat_messages m
   set owner_email = coalesce(
         case when m.from_team
              then (select nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '')
                      from public.venues v where v.id = m.venue_id)
              else lower(btrim(m.author_email)) end, '')
 where m.owner_email is null;

-- The messages of one chat, oldest first (the latest 400).
drop function if exists public.chat_rows(uuid);
create or replace function public.chat_rows(p_venue uuid, p_owner text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id,
           'team', m.from_team,
           'author', m.author,
           'body', m.body,
           'at', m.at,
           'read', m.read_at is not null) order by m.at, m.id), '[]'::jsonb)
    from (select * from public.space_chat_messages x
           where x.venue_id = p_venue
             and (p_owner is null or x.owner_email = p_owner)
           order by x.at desc, x.id desc limit 400) m;
$$;
revoke all on function public.chat_rows(uuid, text) from public, anon, authenticated;

-- The first name a founder's messages are signed with.
create or replace function public.chat_team_name()
returns text language sql stable security definer set search_path = public as $$
  select case when n ~ '^[[:alpha:]]{2,20}$' then initcap(n) end
    from (select split_part(btrim(coalesce(
                   (select p.display_name from public.profiles p where p.id = auth.uid()),
                   '')), ' ', 1) as n) s;
$$;
revoke all on function public.chat_team_name() from public, anon, authenticated;

-- The founders' phones, with the notice opening the chats when it is
-- tapped. notify_phone (migration 25) has no room for an address to
-- open, so this sends the notice itself, to the same place: where
-- that is, is read from notify_phone and not written down a second
-- time. If it cannot be read, the plain notice goes out instead.
create or replace function public.chat_notify(p_title text, p_message text)
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
      'click', 'https://nomadmaps.io/chats/'),
    headers := '{"Content-Type": "application/json"}'::jsonb);
exception when others then
  null; -- a notice never gets in the way of the message itself
end $$;
revoke all on function public.chat_notify(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- owner

create or replace function public.owner_chat(p_venue uuid, p_seen boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em     text := public.owner_email();
  v_name text;
begin
  if em is null then raise exception 'Please sign in.'; end if;
  select name into v_name from public.venues
   where id = p_venue and lower(listing_owner_email) = em;
  if not found then
    raise exception 'This space is not on your account.';
  end if;
  if coalesce(p_seen, true) then
    update public.space_chat_messages
       set read_at = now()
     where venue_id = p_venue and from_team and read_at is null
       and owner_email = em;
  end if;
  return jsonb_build_object('space', v_name, 'messages', public.chat_rows(p_venue, em));
end $$;
revoke all on function public.owner_chat(uuid, boolean) from public, anon;
grant execute on function public.owner_chat(uuid, boolean) to authenticated;

create or replace function public.owner_chat_send(p_venue uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em     text := public.owner_email();
  v      public.venues%rowtype;
  words  text := btrim(coalesce(p_body, ''), E' \t\n\r');
  recent integer;
begin
  if em is null then raise exception 'Please sign in.'; end if;
  select * into v from public.venues
   where id = p_venue and lower(listing_owner_email) = em;
  if not found then
    raise exception 'This space is not on your account.';
  end if;
  if words = '' then raise exception 'The message is empty.'; end if;
  if char_length(words) > 4000 then
    raise exception 'That message is a little long: 4,000 characters at most.';
  end if;
  -- one send at a time per space, so the count below cannot be outrun
  perform pg_advisory_xact_lock(hashtextextended('space_chat:' || p_venue::text, 0));
  select count(*) into recent from public.space_chat_messages
   where venue_id = p_venue and not from_team and at > now() - interval '1 hour';
  if recent >= 40 then
    raise exception 'That is a lot of messages in a short while. Please try again a little later.';
  end if;

  insert into public.space_chat_messages (venue_id, from_team, author, author_email, owner_email, body)
  values (p_venue, false, nullif(btrim(coalesce(v.listing_owner_name, '')), ''), em, em, words);

  -- they are in the chat: what we wrote has been seen
  update public.space_chat_messages
     set read_at = now()
   where venue_id = p_venue and from_team and read_at is null
     and owner_email = em;

  -- the founders' phones
  -- Who wrote, not what: the notice travels outside our own systems,
  -- and what an owner writes here stays in the chat.
  perform public.chat_notify(
    'Chat: ' || coalesce(v.name, 'a space'),
    coalesce(nullif(btrim(coalesce(v.listing_owner_name, '')), ''), 'The owner')
      || ' sent you a message. Tap to open the chats.');

  return jsonb_build_object('space', v.name, 'messages', public.chat_rows(p_venue, em));
end $$;
revoke all on function public.owner_chat_send(uuid, text) from public, anon;
grant execute on function public.owner_chat_send(uuid, text) to authenticated;

-- Per space on this account: how many of our messages are unread.
create or replace function public.owner_chat_unread()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.venue_id, x.n), '{}'::jsonb)
    from (select m.venue_id::text as venue_id, count(*) as n
            from public.space_chat_messages m
            join public.venues v on v.id = m.venue_id
           where public.owner_email() is not null
             and lower(v.listing_owner_email) = public.owner_email()
             and m.owner_email = public.owner_email()
             and m.from_team and m.read_at is null
           group by m.venue_id) x;
$$;
revoke all on function public.owner_chat_unread() from public, anon;
grant execute on function public.owner_chat_unread() to authenticated;

-- ---------------------------------------------------------------- founders

create or replace function public.admin_chats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(r) order by r.waiting desc, r.last_at desc nulls last, r.name), '[]'::jsonb)
      from (
        select v.id as venue_id, v.name, v.city, v.country, v.type as kind,
               v.listing_tier as tier,
               nullif(btrim(coalesce(v.listing_owner_name, '')), '') as owner_name,
               nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '') as owner_email,
               l.at as last_at,
               left(regexp_replace(coalesce(l.body, ''), '\s+', ' ', 'g'), 160) as last_body,
               l.from_team as last_team,
               coalesce(u.n, 0) as unread,
               coalesce(c.n, 0) as messages,
               -- the latest word is theirs: it waits for an answer
               coalesce(not l.from_team, false) as waiting
          from public.venues v
          left join lateral (
            select m.at, m.body, m.from_team
              from public.space_chat_messages m
             where m.venue_id = v.id
             order by m.at desc, m.id desc limit 1) l on true
          left join lateral (
            select count(*) as n from public.space_chat_messages m
             where m.venue_id = v.id and not m.from_team and m.read_at is null) u on true
          left join lateral (
            select count(*) as n from public.space_chat_messages m
             where m.venue_id = v.id) c on true
         where nullif(btrim(coalesce(v.listing_owner_email, '')), '') is not null
            or l.at is not null
         order by coalesce(not l.from_team, false) desc, l.at desc nulls last, v.name
         limit 500) r);
end $$;
revoke all on function public.admin_chats() from public, anon;
grant execute on function public.admin_chats() to authenticated;

create or replace function public.admin_chat(p_venue uuid, p_seen boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v public.venues%rowtype;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into v from public.venues where id = p_venue;
  if not found then raise exception 'Space not found.'; end if;
  if coalesce(p_seen, true) then
    update public.space_chat_messages
       set read_at = now()
     where venue_id = p_venue and not from_team and read_at is null;
  end if;
  return jsonb_build_object(
    'space', v.name,
    'city', v.city,
    'country', v.country,
    'owner_name', nullif(btrim(coalesce(v.listing_owner_name, '')), ''),
    'owner_email', nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), ''),
    'messages', public.chat_rows(p_venue, null));
end $$;
revoke all on function public.admin_chat(uuid, boolean) from public, anon;
grant execute on function public.admin_chat(uuid, boolean) to authenticated;

create or replace function public.admin_chat_send(p_venue uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v     public.venues%rowtype;
  words text := btrim(coalesce(p_body, ''), E' \t\n\r');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into v from public.venues where id = p_venue;
  if not found then raise exception 'Space not found.'; end if;
  if nullif(btrim(coalesce(v.listing_owner_email, '')), '') is null then
    raise exception 'This space has no owner yet, so nobody would read it.';
  end if;
  if words = '' then raise exception 'The message is empty.'; end if;
  if char_length(words) > 4000 then
    raise exception 'That message is a little long: 4,000 characters at most.';
  end if;
  insert into public.space_chat_messages (venue_id, from_team, author, author_email, owner_email, body)
  values (p_venue, true, public.chat_team_name(),
          (select email from auth.users where id = auth.uid()),
          lower(btrim(v.listing_owner_email)), words);
  -- answering is having read
  update public.space_chat_messages
     set read_at = now()
   where venue_id = p_venue and not from_team and read_at is null;
  return public.admin_chat(p_venue, false);
end $$;
revoke all on function public.admin_chat_send(uuid, text) from public, anon;
grant execute on function public.admin_chat_send(uuid, text) to authenticated;

create or replace function public.admin_chats_unread()
returns integer language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then return 0; end if;
  return (select count(*)::integer from public.space_chat_messages m
           where not m.from_team and m.read_at is null);
end $$;
revoke all on function public.admin_chats_unread() from public, anon;
grant execute on function public.admin_chats_unread() to authenticated;

-- ---------------------------------------------------------------- the owner's email
-- What we wrote and the owner has not seen, emailed once: a minute
-- after the last of it, so several messages in a row are one email.
-- Seen in the chat before that: no email at all.
create or replace function public.chat_email_sync()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r     record;
  n     integer := 0;
  who   text;
  words text;
begin
  -- read already: nothing to send
  update public.space_chat_messages
     set emailed_at = now()
   where from_team and emailed_at is null and read_at is not null;

  for r in
    select m.venue_id, m.owner_email, v.name,
           nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '') as em
      from public.space_chat_messages m
      join public.venues v on v.id = m.venue_id
     where m.from_team and m.emailed_at is null
     group by m.venue_id, m.owner_email, v.name, v.listing_owner_email
    having max(m.at) < now() - interval '60 seconds'
     order by min(m.at)
     limit 40
  loop
    begin
      -- marked and read in one statement: what is marked is exactly
      -- what is sent, and a second run finds nothing left to send
      with marked as (
        update public.space_chat_messages x
           set emailed_at = now()
         where x.venue_id = r.venue_id and x.from_team and x.emailed_at is null
           and x.owner_email is not distinct from r.owner_email
        returning x.id, x.at, x.author, x.body, x.read_at)
      select (array_agg(k.author order by k.at desc, k.id desc)
                filter (where k.author is not null))[1],
             string_agg(k.body, E'\n\n' order by k.at, k.id)
        into who, words
        from marked k
       where k.read_at is null;
      -- only to the owner it was written for, if the space is still theirs
      if words is not null and r.em is not null and r.em = r.owner_email then
        perform public.send_owner_email(
          r.em,
          coalesce(who || ' from Nomadwise', 'Nomadwise')
            || ' sent you a message about ' || coalesce(r.name, 'your space'),
          coalesce(who || ' from Nomadwise', 'Nomadwise')
            || ' sent you a message about ' || coalesce(r.name, 'your space') || ':'
            || E'\n\n' || case when char_length(words) > 6000
                                 then left(words, 6000) || E'\n\n' || '(The rest is in the chat.)'
                                 else words end
            || E'\n\n' || 'You can answer in your Owner account, under Inbox & support. '
            || 'If you reply to this email instead, it reaches us too.',
          'chat', r.venue_id::text,
          'Open the chat', 'https://nomadmaps.io/owner?chat=' || r.venue_id::text);
        n := n + 1;
      end if;
    exception when others then
      -- one space's email must not stop the others; tried again next run
      null;
    end;
  end loop;
  return n;
end $$;
revoke all on function public.chat_email_sync() from public, anon, authenticated;
grant execute on function public.chat_email_sync() to service_role;

do $$
begin
  perform cron.unschedule('chat-email-sync');
exception when others then null;
end $$;
select cron.schedule('chat-email-sync', '*/2 * * * *',
  'select public.chat_email_sync()');
