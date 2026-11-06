-- ============================================================
-- Migration 281: numbers for the All locations list.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026 (options E, F and G): owners with two or more
-- locations land on an All locations list, one row per location with
-- its plan and its last 30 days: page views, times shown in Google and
-- requests. owner_locations() returns those numbers for every space on
-- the signed-in owner's account, in one call. Google runs a few days
-- behind, so its 30 days end on the latest day we have, as on the
-- Performance tab.
-- ============================================================

create or replace function public.owner_locations()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  em    text := public.owner_email();
  today date := (now() at time zone 'utc')::date;
  g_end date;
begin
  if em is null then raise exception 'Please sign in.'; end if;
  select max(day) into g_end from public.page_google_days;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', v.id,
             'views', coalesce((select sum(c.n) from public.page_counts c
                                 where c.venue_id = v.id and c.kind = 'view'
                                   and c.day > today - 30), 0),
             'google', coalesce((select sum(g.impressions) from public.page_google_days g
                                  where g.venue_id = v.id and g_end is not null
                                    and g.day > g_end - 30 and g.day <= g_end), 0),
             'requests', (select count(*) from public.enquiries e
                           where e.venue_id = v.id and e.status <> 'closed'
                             and e.created_at > now() - interval '30 days'))
             order by v.name)
      from public.venues v
     where lower(coalesce(v.listing_owner_email, '')) = em), '[]'::jsonb);
end $$;

revoke all on function public.owner_locations() from public, anon;
grant execute on function public.owner_locations() to authenticated;
