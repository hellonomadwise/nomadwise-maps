-- ============================================================
-- Nomadwise Maps — migration 31: team accounts off the leaderboard
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- Accounts marked as Team (Users -> Group) no longer appear on
-- the public leaderboard. Friends and customers stay ranked.
-- ============================================================

create or replace view public.leaderboard as
select
  p.id as user_id,
  coalesce(nullif(p.display_name, ''), 'Nomad') as display_name,
  p.avatar_url,
  p.created_at as member_since,
  coalesce((select sum(l.amount) from public.coin_ledger l
             where l.user_id = p.id
               and l.amount > 0
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
from public.profiles p
where p.cohort is distinct from 'team';

grant select on public.leaderboard to anon, authenticated;
