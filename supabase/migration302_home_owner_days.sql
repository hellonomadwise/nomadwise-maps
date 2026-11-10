-- ============================================================
-- Migration 302: owners each day, for Home
-- ============================================================
-- Jonathan, 10 Nov 2026, on Home's Where we stand: "I would like to
-- see daily activity bar chart on users claimed as well as users
-- logged in, users updated info".
--
-- admin_home_owner_days(p_days) gives one row per day for the last
-- p_days days (today included), each with three counts and the spaces
-- behind them, so a tapped bar can list who:
--   claimed    spaces whose first claim (free or paid) came that day
--   signed_in  spaces whose owner opened their Owner account that day
--   updated    spaces whose owner sent changes for review that day
-- Our own team's addresses and test claims are left out, as in
-- admin_home's claims.
-- ============================================================

create or replace function public.admin_home_owner_days(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  today date := (now() at time zone 'Europe/London')::date;
  d0    date;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  d0 := today - (greatest(7, least(coalesce(p_days, 30), 90)) - 1);

  return (
    with team as (
      select lower(email) as email from public.owner_flow_team_emails
    ),
    claimed as (
      select (min(lc.created_at) at time zone 'Europe/London')::date as day, lc.venue_id
        from public.listing_claims lc
       where lc.status in ('free', 'paid') and lc.venue_id is not null
         and lower(coalesce(lc.owner_email, '')) not like '%nomadwise%'
         and lower(coalesce(lc.owner_email, '')) not in (select email from team)
         and coalesce(lc.owner_name, '') not ilike '%test%'
         and not exists (select 1 from public.space_contacts c
                          where c.venue_id = lc.venue_id and c.is_test)
       group by lc.venue_id
    ),
    signed as (
      select distinct v.day, v.venue_id
        from public.owner_visits v
       where v.day >= d0
         and lower(coalesce(v.owner_email, '')) not like '%nomadwise%'
         and lower(coalesce(v.owner_email, '')) not in (select email from team)
    ),
    updated as (
      select distinct (e.created_at at time zone 'Europe/London')::date as day, e.venue_id
        from public.owner_draft_events e
       where e.status = 'submitted'
         and e.created_at >= d0 - 1
         and lower(coalesce(e.owner_email, '')) not like '%nomadwise%'
         and lower(coalesce(e.owner_email, '')) not in (select email from team)
    ),
    names as (
      select id, name from public.venues
    )
    select jsonb_agg(jsonb_build_object(
             'day', to_char(g.day, 'YYYY-MM-DD'),
             'claimed', (select count(*) from claimed c where c.day = g.day),
             'signed_in', (select count(*) from signed s where s.day = g.day),
             'updated', (select count(*) from updated u where u.day = g.day),
             'claimed_names', (select coalesce(jsonb_agg(n.name order by n.name), '[]'::jsonb)
                                 from claimed c join names n on n.id = c.venue_id where c.day = g.day),
             'signed_in_names', (select coalesce(jsonb_agg(n.name order by n.name), '[]'::jsonb)
                                   from signed s join names n on n.id = s.venue_id where s.day = g.day),
             'updated_names', (select coalesce(jsonb_agg(n.name order by n.name), '[]'::jsonb)
                                 from updated u join names n on n.id = u.venue_id where u.day = g.day))
           order by g.day)
      from (select generate_series(d0, today, interval '1 day')::date as day) g
  );
end $$;

revoke all on function public.admin_home_owner_days(integer) from public, anon;
grant execute on function public.admin_home_owner_days(integer) to authenticated;

-- Home reads it with the rest of its numbers.
select public.pm_patch_fn('public.admin_home()',
$a$    'targets', (select coalesce(jsonb_object_agg(t.key, t.value), '{}'::jsonb)$a$,
$a$    -- owners each day, last 30 days (migration 302)
    'owner_days', public.admin_home_owner_days(30),

    'targets', (select coalesce(jsonb_object_agg(t.key, t.value), '{}'::jsonb)$a$,
$m$owners each day, last 30 days (migration 302)$m$);
