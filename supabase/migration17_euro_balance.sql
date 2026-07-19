-- ============================================================
-- Nomadwise Maps — migration 17: euro balance + conversion
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- Coins convert to a euro balance (100 coins = €1, so 1 coin =
-- 1 cent). The leaderboard now counts lifetime EARNED coins, so
-- converting never costs anyone their position.
-- ============================================================

-- 1. The euro side of the wallet.
create table if not exists public.euro_ledger (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id),
  cents      integer not null,          -- positive = credit
  note       text,
  created_at timestamptz not null default now()
);

alter table public.euro_ledger enable row level security;

drop policy if exists "own euro rows" on public.euro_ledger;
create policy "own euro rows" on public.euro_ledger
  for select using (auth.uid() = user_id);
-- No insert/update policies: only the function below may write.

-- 2. Convert the caller's whole withdrawable coin balance.
create or replace function public.convert_coins_to_euros()
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  coins int;
begin
  if uid is null then
    return json_build_object('error', 'not signed in');
  end if;
  select coalesce(sum(amount), 0) into coins
    from public.coin_ledger
   where user_id = uid and status = 'withdrawable';
  if coins <= 0 then
    return json_build_object('coins', 0, 'cents', 0);
  end if;
  insert into public.coin_ledger (user_id, amount, status, note)
  values (uid, -coins, 'withdrawable', 'Converted to euros');
  -- 100 coins = €1  ->  1 coin = 1 cent.
  insert into public.euro_ledger (user_id, cents, note)
  values (uid, coins, 'Converted from ' || coins || ' coins');
  return json_build_object('coins', coins, 'cents', coins);
end $$;

revoke all on function public.convert_coins_to_euros() from public, anon;
grant execute on function public.convert_coins_to_euros() to authenticated;

-- 3. Leaderboard counts lifetime EARNED coins (conversions and other
--    deductions never lower anyone's score).
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
from public.profiles p;

grant select on public.leaderboard to anon, authenticated;
