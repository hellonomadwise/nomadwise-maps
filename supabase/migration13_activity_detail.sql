-- ============================================================
-- Nomadwise Maps — migration 13: full detail in admin activity
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

-- The function's answer gains new columns, so it must be dropped
-- and recreated (Postgres will not change a function's shape in place).
drop function if exists public.admin_user_activity(uuid);

create function public.admin_user_activity(target uuid)
returns table (
  id uuid,
  kind text,
  status text,
  created_at timestamptz,
  verified_at timestamptz,
  venue_id uuid,
  venue_name text,
  city text,
  gps_distance_m double precision,
  coins int,
  payload jsonb,
  photo_path text
)
language sql stable security definer set search_path = public as
$$
  select
    s.id,
    s.kind,
    s.status,
    s.created_at,
    s.verified_at,
    s.venue_id,
    v.name,
    v.city,
    s.gps_distance_m::double precision,
    coalesce((select sum(l.amount) from public.coin_ledger l
               where l.submission_id = s.id
                 and l.status <> 'cancelled'), 0)::int,
    s.payload,
    s.photo_path
  from public.submissions s
  left join public.venues v on v.id = s.venue_id
  where public.is_admin() and s.user_id = target
  order by s.created_at desc
  limit 300
$$;

revoke all on function public.admin_user_activity(uuid) from public, anon;
grant execute on function public.admin_user_activity(uuid) to authenticated;
