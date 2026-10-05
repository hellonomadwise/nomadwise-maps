-- ============================================================
-- Migration 142: "Choose a page" as an inbox.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026: "once I've reviewed and checked and pushed
-- with a listing, I would like it to cycle to the bottom of the list
-- or move into a different section ... so that there is a kind of an
-- inbox list of todo, so it cycles, and I can just focus on the top of
-- the list all the time, unless I want to search."
--
-- The list of pages (admin_upgrades_pages) now runs in three parts:
--   1. pages with a draft waiting for a Go, or one that needs a look;
--   2. pages not dealt with yet, the most promising first (as before);
--   3. pages dealt with, the longest ago first, so that when the rest
--      is done the list comes round again.
-- A page is dealt with when a Go or a skip was pressed on a draft for
-- it, when an upgrade was requested for it, or when it was marked
-- "Done for now" by hand (upgrade_page_marks). A new draft brings it
-- back to the top by itself. "Back to the list" puts it back in part
-- 2 by hand. A new filter, "done", shows part 3 alone, the latest
-- first, without the requested pages (those are in hand, not done,
-- and have their own filter). Searching still finds any page.
--
-- Nothing here changes a page, a draft or the website.
-- ============================================================

create table if not exists public.upgrade_page_marks (
  venue_id    uuid primary key references public.venues(id) on delete cascade,
  done_at     timestamptz,   -- "Done for now", pressed by hand
  reopened_at timestamptz,   -- "Back to the list": what was done before this no longer counts
  marked_by   text
);
alter table public.upgrade_page_marks enable row level security;
drop policy if exists "upgrade_page_marks admin" on public.upgrade_page_marks;
create policy "upgrade_page_marks admin" on public.upgrade_page_marks
  for select to authenticated using (public.is_admin());

-- "Done for now" (p_done true) or "Back to the list" (false).
create or replace function public.admin_upgrade_page_done(p_venue uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if p_venue is null or not exists (select 1 from public.venues where id = p_venue) then
    raise exception 'no such page';
  end if;
  if coalesce(p_done, true) then
    insert into public.upgrade_page_marks (venue_id, done_at, marked_by)
    values (p_venue, now(), public.upgrades_admin_email())
    on conflict (venue_id) do update
      set done_at = excluded.done_at, marked_by = excluded.marked_by;
  else
    insert into public.upgrade_page_marks (venue_id, reopened_at, marked_by)
    values (p_venue, now(), public.upgrades_admin_email())
    on conflict (venue_id) do update
      set reopened_at = excluded.reopened_at, marked_by = excluded.marked_by;
  end if;
end $$;
revoke all on function public.admin_upgrade_page_done(uuid, boolean) from public, anon;
grant execute on function public.admin_upgrade_page_done(uuid, boolean) to authenticated;

create or replace function public.admin_upgrades_pages(
  p_q text default null, p_filter text default null, p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q   text := nullif(trim(coalesce(p_q, '')), '');
  flt text := coalesce(p_filter, '');
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select coalesce(jsonb_agg(x.row), '[]'::jsonb) into out
    from (
      select jsonb_build_object(
               'venue_id', v.id, 'name', v.name, 'type', v.type,
               'area', coalesce(f.facts ->> 'area', v.neighbourhood),
               'region', f.facts ->> 'region',
               'country', v.country, 'slug', v.webflow_slug,
               'owned', v.listing_owner_email is not null,
               'impact', public.upgrade_impact(v, 'description'),
               'reason', public.upgrade_reason(v, 'description'),
               'title', f.facts ->> 'title',
               'meta_generic', public.upgrade_meta_is_generic(v),
               'desc_words', coalesce((f.facts ->> 'desc_words')::int, 0),
               'photos', (f.facts ->> 'photos')::int,
               'request', (select jsonb_build_object('id', r.id, 'note', r.note,
                                                     'created_at', r.created_at)
                             from public.upgrade_requests r
                            where r.venue_id = v.id and r.status = 'open' limit 1),
               'waiting', (select count(*) from public.page_upgrades u
                            where u.venue_id = v.id and u.kind <> 'photos'
                              and u.status = 'proposed'),
               'on_way', (select count(*) from public.page_upgrades u
                           where u.venue_id = v.id and u.kind <> 'photos'
                             and u.status in ('approved', 'undo_requested')),
               'live', (select count(*) from public.page_upgrades u
                         where u.venue_id = v.id and u.kind <> 'photos'
                           and u.status = 'applied'),
               'failed', (select count(*) from public.page_upgrades u
                           where u.venue_id = v.id and u.kind <> 'photos'
                             and u.status = 'failed'),
               -- where it stands in the inbox: 0 a draft waits for
               -- you, 1 not dealt with yet, 2 dealt with
               'section', s.section,
               'done', s.section = 2,
               'done_at', case when s.section = 2 then s.dealt_at end,
               'done_how', case when s.section = 2 then s.dealt_how end) as row
        from public.venues v
        left join public.venue_page_facts f on f.venue_id = v.id
        cross join lateral (
          select d.dealt_at, d.dealt_how,
                 case when exists (select 1 from public.page_upgrades u
                                    where u.venue_id = v.id and u.kind <> 'photos'
                                      and u.status in ('proposed', 'failed')) then 0
                      when d.dealt_at is not null
                       and d.dealt_at > coalesce(m.reopened_at, '-infinity'::timestamptz) then 2
                      else 1 end as section
            from (select 1) one
            left join public.upgrade_page_marks m on m.venue_id = v.id
            left join lateral (
              -- the last thing you did with it: a Go or a skip on a
              -- draft, a request to have it drafted, or "Done for now"
              select t.at as dealt_at, t.how as dealt_how
                from (select max(u.decided_at) as at, 'go' as how
                        from public.page_upgrades u
                       where u.venue_id = v.id and u.kind <> 'photos'
                         and u.decided_at is not null
                         and u.status in ('approved', 'applied', 'skipped',
                                          'undo_requested', 'undone')
                      union all
                      select max(r.created_at), 'requested'
                        from public.upgrade_requests r
                       where r.venue_id = v.id and r.status = 'open'
                      union all
                      select m.done_at, 'marked') t
               where t.at is not null
               order by t.at desc
               limit 1) d on true) s
       where public.upgrade_page_is_live(v)
         and (q is null
              or v.name ilike '%' || q || '%'
              or coalesce(v.webflow_slug, '') ilike '%' || q || '%'
              or coalesce(f.facts ->> 'area', v.neighbourhood, '') ilike '%' || q || '%'
              or coalesce(f.facts ->> 'region', '') ilike '%' || q || '%'
              or coalesce(v.country, '') ilike '%' || q || '%')
         and (flt <> 'requested'
              or exists (select 1 from public.upgrade_requests r
                          where r.venue_id = v.id and r.status = 'open'))
         and (flt <> 'waiting'
              or exists (select 1 from public.page_upgrades u
                          where u.venue_id = v.id and u.kind <> 'photos'
                            and u.status in ('proposed', 'failed')))
         and (flt <> 'search'
              or exists (select 1 from public.page_search ps where ps.slug = v.webflow_slug))
         -- a requested page is in hand, not done: under "Requested"
         and (flt <> 'done' or (s.section = 2 and s.dealt_how <> 'requested'))
       -- An inbox: drafts waiting for you, then the pages not dealt
       -- with, the most promising first; the pages dealt with last,
       -- the longest ago first, so the list comes round again. Under
       -- "Done" the latest comes first.
       order by case when flt = 'done' then 0 else s.section end,
                case when flt = 'done' then s.dealt_at end desc nulls last,
                case when s.section = 2 and flt <> 'done' then s.dealt_at end asc nulls last,
                public.upgrade_impact(v, 'description') desc, v.name
       limit greatest(1, least(coalesce(p_limit, 60), 300))
    ) x;
  return out;
end $$;

revoke all on function public.admin_upgrades_pages(text, text, integer) from public, anon;
grant execute on function public.admin_upgrades_pages(text, text, integer) to authenticated;
