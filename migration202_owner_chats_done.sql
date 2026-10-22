-- ============================================================
-- Migration 202: owner chats can be marked done, like website chats.
--
-- Jonathan, 22 Oct 2026, on Chats (Owners): "an open and done, similar
-- to website", so the list reads like an inbox of what is not closed;
-- and the spaces with no messages yet kept, but tucked away.
--
--   space_chat_done   one row per space: when a founder marked its
--                     chat done. The chat counts as done only while
--                     nothing has been written since, so a new message
--                     (theirs or ours) reopens it by itself.
--   admin_chat_done(venue, done)   mark done, or reopen.
--   admin_chats()     (migration 198) plus done and done_at.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create table if not exists public.space_chat_done (
  venue_id uuid primary key references public.venues(id) on delete cascade,
  done_at  timestamptz not null default now(),
  done_by  text
);
alter table public.space_chat_done enable row level security;
-- No policy: only the functions below read or write it.
revoke all on public.space_chat_done from public, anon, authenticated;

create or replace function public.admin_chat_done(p_venue uuid, p_done boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;
  if coalesce(p_done, true) then
    insert into public.space_chat_done (venue_id, done_at, done_by)
    values (p_venue, now(), coalesce(public.chat_team_name(), 'Jonathan'))
    on conflict (venue_id) do update
       set done_at = now(), done_by = excluded.done_by;
  else
    delete from public.space_chat_done where venue_id = p_venue;
  end if;
  return jsonb_build_object('venue_id', p_venue, 'done', coalesce(p_done, true));
end $$;
revoke all on function public.admin_chat_done(uuid, boolean) from public, anon;
grant execute on function public.admin_chat_done(uuid, boolean) to authenticated;

-- Chats (migration 198), plus done / done_at.
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
               greatest(v.owner_content_at, d.at) as changed_at,
               -- marked done, and nothing written since (migration 202)
               coalesce(dn.done_at is not null and l.at is not null
                        and dn.done_at >= l.at, false) as done,
               dn.done_at
          from public.venues v
          left join public.space_chat_done dn on dn.venue_id = v.id
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
