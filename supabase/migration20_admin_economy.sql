-- ============================================================
-- Nomadwise Maps — migration 20: economy totals for the admin
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

create or replace function public.admin_economy()
returns json language sql stable security definer set search_path = public as
$$
  select case when public.is_admin() then json_build_object(
    'coins_withdrawable',
      coalesce((select sum(amount) from public.coin_ledger
                 where status = 'withdrawable'), 0),
    'coins_pending',
      coalesce((select sum(amount) from public.coin_ledger
                 where status = 'pending'), 0),
    'euro_cents',
      coalesce((select sum(cents) from public.euro_ledger), 0),
    'coins_earned_total',
      coalesce((select sum(amount) from public.coin_ledger
                 where amount > 0
                   and status in ('withdrawable','paid_out')), 0)
  ) else null end
$$;

revoke all on function public.admin_economy() from public, anon;
grant execute on function public.admin_economy() to authenticated;
