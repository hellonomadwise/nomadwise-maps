-- ============================================================
-- Nomadwise Maps — migration 9: leaderboard, live activity, public stats
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

-- Public per-user stats: nickname + numbers only (no emails, no ids leaked
-- beyond what the app already uses internally).
create or replace view public.leaderboard as
select
  p.id as user_id,
  coalesce(nullif(p.display_name, ''), 'Nomad') as display_name,
  p.created_at as member_since,
  coalesce((select sum(l.amount) from public.coin_ledger l
             where l.user_id = p.id
               and l.status in ('withdrawable','paid_out')), 0)::int as coins,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified')::int as verified_count,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified'
      and s.kind = 'new_venue')::int as reviews,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified'
      and s.kind = 'confirm')::int as confirms,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified'
      and s.kind = 'wifi_test')::int as wifi_tests,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified'
      and s.kind = 'wifi_login')::int as wifi_logins
from public.profiles p;

grant select on public.leaderboard to anon, authenticated;

-- Recent verified activity, newest first: who did what, where.
create or replace view public.live_activity as
select
  coalesce(nullif(p.display_name, ''), 'Nomad') as display_name,
  s.user_id,
  s.kind,
  s.verified_at,
  v.name as venue_name,
  v.city
from public.submissions s
join public.profiles p on p.id = s.user_id
left join public.venues v on v.id = s.venue_id
where s.status = 'verified' and s.verified_at is not null
order by s.verified_at desc
limit 100;

grant select on public.live_activity to anon, authenticated;
