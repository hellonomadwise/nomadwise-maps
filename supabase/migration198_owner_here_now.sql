-- ============================================================
-- Migration 198: talking to an owner while they are there.
--
-- Jonathan, 22 Oct 2026: owners make changes or sign in, and he
-- wants to be there for any questions "in a human natural way", only
-- when he sees them online and is free himself (he had WhatsApped
-- Sierra Cartel by hand after they changed their photos). Chosen:
--
--   * Online now. The Owner account says "still here" every minute
--     while it is on screen (owner_here). Chats shows who is in
--     their Owner account right now (admin_chats: here, here_since),
--     and the founders' phones get ONE notice when an owner arrives
--     (at most once in 6 hours per space). Tapping it opens that
--     space's chat (nomadmaps.io/chats/#space-<id>).
--   * Say hello. admin_chats also gives changed_at (their last saved
--     change), so the app can offer a fitting first line to edit.
--   * Our message pops up for them. owner_chat_waiting gives the
--     newest unread message from us per space WITHOUT marking it
--     read, so the Owner account can show it in a small card. If
--     they do not open it, the email still goes as before (161).
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create table if not exists public.owner_presence (
  venue_id    uuid primary key references public.venues(id) on delete cascade,
  owner_email text not null,
  since       timestamptz not null default now(),
  last_beat   timestamptz not null default now(),
  told_at     timestamptz
);
alter table public.owner_presence enable row level security;
-- No policy: only the functions below read or write it.
revoke all on public.owner_presence from public, anon, authenticated;

-- The founders' phones, with an address to open when tapped. As
-- chat_notify (migration 161), which always opens the chats list.
create or replace function public.chat_notify_open(
  p_title text, p_message text, p_click text)
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
    perform public.notify_phone(p_title, p_message, 'wave');
    return;
  end if;
  perform net.http_post(
    url := 'https://ntfy.sh',
    body := jsonb_build_object(
      'topic', topic,
      'title', p_title,
      'message', p_message,
      'tags', array['wave'],
      'click', coalesce(p_click, 'https://nomadmaps.io/chats/')),
    headers := '{"Content-Type": "application/json"}'::jsonb);
exception when others then
  null; -- a notice never gets in the way
end $$;
revoke all on function public.chat_notify_open(text, text, text) from public, anon, authenticated;

-- The Owner account, every minute while it is on screen.
create or replace function public.owner_here()
returns void language plpgsql security definer set search_path = public as $$
declare
  em      text := public.owner_email();
  r       record;
  arrived text[] := '{}';
  first   uuid;
  who     text;
begin
  -- A founder looking at their own test space is not an owner.
  if em is null or coalesce(public.is_admin(), false) then return; end if;

  for r in
    select v.id, v.name, v.listing_owner_name,
           p.last_beat, p.told_at, p.owner_email as was
      from public.venues v
      left join public.owner_presence p on p.venue_id = v.id
     where lower(btrim(v.listing_owner_email)) = em
     order by v.name
     limit 20
  loop
    insert into public.owner_presence (venue_id, owner_email)
    values (r.id, em)
    on conflict (venue_id) do update
       set since = case when public.owner_presence.last_beat < now() - interval '10 minutes'
                          or public.owner_presence.owner_email <> em
                        then now() else public.owner_presence.since end,
           last_beat = now(),
           owner_email = em;

    -- just arrived, and not told about this space in the last 6 hours
    if (r.last_beat is null or r.last_beat < now() - interval '10 minutes'
        or r.was <> em)
       and (r.told_at is null or r.told_at < now() - interval '6 hours') then
      arrived := arrived || r.name;
      first := coalesce(first, r.id);
      who := coalesce(who, nullif(split_part(btrim(coalesce(r.listing_owner_name, '')), ' ', 1), ''));
      update public.owner_presence set told_at = now() where venue_id = r.id;
    end if;
  end loop;

  if coalesce(array_length(arrived, 1), 0) > 0 then
    perform public.chat_notify_open(
      array_to_string(arrived, ', ') || ': in their Owner account',
      coalesce(who, 'The owner') || ' is signed in now. Tap to open the chat '
        || 'if you would like to say hello.',
      'https://nomadmaps.io/chats/#space-' || first::text);
  end if;
end $$;
revoke all on function public.owner_here() from public, anon;
grant execute on function public.owner_here() to authenticated;

-- For the card in the Owner account: per space, our newest message
-- they have not read, and how many are unread. Reading this does not
-- mark anything as read.
create or replace function public.owner_chat_waiting()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb)
    from (select distinct on (m.venue_id)
                 m.id, m.venue_id, v.name as venue_name, m.author,
                 left(m.body, 600) as body, m.at,
                 (select count(*) from public.space_chat_messages c
                   where c.venue_id = m.venue_id and c.from_team
                     and c.read_at is null and c.owner_email = m.owner_email) as unread
            from public.space_chat_messages m
            join public.venues v on v.id = m.venue_id
           where public.owner_email() is not null
             and lower(v.listing_owner_email) = public.owner_email()
             and m.owner_email = public.owner_email()
             and m.from_team and m.read_at is null
           order by m.venue_id, m.at desc, m.id desc) x;
$$;
revoke all on function public.owner_chat_waiting() from public, anon;
grant execute on function public.owner_chat_waiting() to authenticated;

-- Chats (migration 161), plus: here (in their Owner account in the
-- last 3 minutes), here_since, and changed_at (their last saved
-- change, for the first line the app offers).
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
               coalesce(not l.from_team, false) as waiting,
               coalesce(p.last_beat > now() - interval '3 minutes'
                        and p.owner_email = lower(btrim(coalesce(v.listing_owner_email, ''))),
                        false) as here,
               case when p.last_beat > now() - interval '3 minutes' then p.since end as here_since,
               greatest(v.owner_content_at, d.at) as changed_at
          from public.venues v
          left join public.owner_presence p on p.venue_id = v.id
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
          left join lateral (
            select max(coalesce(od.submitted_at, od.updated_at)) as at
              from public.owner_drafts od
             where od.venue_id = v.id) d on true
         where nullif(btrim(coalesce(v.listing_owner_email, '')), '') is not null
            or l.at is not null
         order by coalesce(not l.from_team, false) desc, l.at desc nulls last, v.name
         limit 500) r);
end $$;
revoke all on function public.admin_chats() from public, anon;
grant execute on function public.admin_chats() to authenticated;

notify pgrst, 'reload schema';
