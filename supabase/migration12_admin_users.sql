-- ============================================================
-- Nomadwise Maps — migration 12: admin user directory
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

-- 1. Everyone who has an account, with email and sign-in info.
--    Returns nothing unless the caller is the admin.
create or replace function public.admin_users()
returns table (
  id uuid,
  email text,
  display_name text,
  avatar_url text,
  is_admin boolean,
  joined_at timestamptz,
  last_sign_in_at timestamptz,
  coins_confirmed int,
  coins_pending int,
  submissions_total int,
  submissions_verified int,
  submissions_pending int,
  submissions_rejected int
)
language sql stable security definer set search_path = public as
$$
  select
    u.id,
    u.email::text,
    coalesce(nullif(p.display_name, ''), 'Nomad'),
    p.avatar_url,
    coalesce(p.is_admin, false),
    u.created_at,
    u.last_sign_in_at,
    coalesce((select sum(l.amount) from public.coin_ledger l
               where l.user_id = u.id
                 and l.status in ('withdrawable','paid_out')), 0)::int,
    coalesce((select sum(l.amount) from public.coin_ledger l
               where l.user_id = u.id and l.status = 'pending'), 0)::int,
    (select count(*) from public.submissions s
      where s.user_id = u.id)::int,
    (select count(*) from public.submissions s
      where s.user_id = u.id and s.status = 'verified')::int,
    (select count(*) from public.submissions s
      where s.user_id = u.id and s.status = 'pending')::int,
    (select count(*) from public.submissions s
      where s.user_id = u.id and s.status = 'rejected')::int
  from auth.users u
  left join public.profiles p on p.id = u.id
  where public.is_admin()
  order by u.created_at desc
$$;

revoke all on function public.admin_users() from public, anon;
grant execute on function public.admin_users() to authenticated;

-- 2. One user's full activity trail. Admin-only, same guard.
create or replace function public.admin_user_activity(target uuid)
returns table (
  kind text,
  status text,
  created_at timestamptz,
  verified_at timestamptz,
  venue_name text,
  city text,
  gps_distance_m double precision,
  coins int
)
language sql stable security definer set search_path = public as
$$
  select
    s.kind,
    s.status,
    s.created_at,
    s.verified_at,
    v.name,
    v.city,
    s.gps_distance_m::double precision,
    coalesce((select sum(l.amount) from public.coin_ledger l
               where l.submission_id = s.id
                 and l.status <> 'cancelled'), 0)::int
  from public.submissions s
  left join public.venues v on v.id = s.venue_id
  where public.is_admin() and s.user_id = target
  order by s.created_at desc
  limit 300
$$;

revoke all on function public.admin_user_activity(uuid) from public, anon;
grant execute on function public.admin_user_activity(uuid) to authenticated;
