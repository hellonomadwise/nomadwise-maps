-- ============================================================
-- Nomadwise Maps — migration 22: economy totals split by group
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- The admin economy numbers now come in three flavours:
--   all      = everyone except the team
--   friend   = accounts marked as Friend
--   customer = everyone else (except team and friends)
-- Team coins are never counted anywhere.
-- ============================================================

create or replace function public.admin_economy()
returns json language sql stable security definer set search_path = public as
$$
  with lc as (
    select l.amount, l.status,
           coalesce(p.cohort, 'customer') as cohort
      from public.coin_ledger l
      left join public.profiles p on p.id = l.user_id
  ),
  le as (
    select e.cents,
           coalesce(p.cohort, 'customer') as cohort
      from public.euro_ledger e
      left join public.profiles p on p.id = e.user_id
  )
  select case when public.is_admin() then json_build_object(
    'all', json_build_object(
      'coins_withdrawable', coalesce((select sum(amount) from lc
        where cohort <> 'team' and status = 'withdrawable'), 0),
      'coins_pending', coalesce((select sum(amount) from lc
        where cohort <> 'team' and status = 'pending'), 0),
      'euro_cents', coalesce((select sum(cents) from le
        where cohort <> 'team'), 0)
    ),
    'friend', json_build_object(
      'coins_withdrawable', coalesce((select sum(amount) from lc
        where cohort = 'friend' and status = 'withdrawable'), 0),
      'coins_pending', coalesce((select sum(amount) from lc
        where cohort = 'friend' and status = 'pending'), 0),
      'euro_cents', coalesce((select sum(cents) from le
        where cohort = 'friend'), 0)
    ),
    'customer', json_build_object(
      'coins_withdrawable', coalesce((select sum(amount) from lc
        where cohort = 'customer' and status = 'withdrawable'), 0),
      'coins_pending', coalesce((select sum(amount) from lc
        where cohort = 'customer' and status = 'pending'), 0),
      'euro_cents', coalesce((select sum(cents) from le
        where cohort = 'customer'), 0)
    )
  ) else null end
$$;

revoke all on function public.admin_economy() from public, anon;
grant execute on function public.admin_economy() to authenticated;
