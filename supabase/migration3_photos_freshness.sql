-- ============================================================
-- Nomadwise Maps — migration 3: freshness tracking + photo gallery
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- (Safe to run more than once.)
-- ============================================================

-- ---------- 1. When was each venue last confirmed? ----------
alter table public.venues add column if not exists last_confirmed_at timestamptz;

-- Backfill from already-verified confirmations
update public.venues v
   set last_confirmed_at = s.max_verified
  from (select venue_id, max(verified_at) as max_verified
          from public.submissions
         where kind = 'confirm' and status = 'verified'
         group by venue_id) s
 where s.venue_id = v.id;

-- Keep it up to date automatically (extends the existing confirm-merge)
create or replace function public.apply_confirm_payload()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'verified' and old.status <> 'verified'
     and new.kind = 'confirm' and new.venue_id is not null then
    update public.venues v set
      laptops_allowed     = coalesce((new.payload->>'laptops_allowed')::boolean, v.laptops_allowed),
      wifi_speed_mbps     = coalesce((new.payload->>'wifi_speed_mbps')::numeric, v.wifi_speed_mbps),
      power_outlets       = coalesce((new.payload->>'power_outlets')::boolean, v.power_outlets),
      aircon              = coalesce((new.payload->>'aircon')::boolean, v.aircon),
      comfortable_seating = coalesce((new.payload->>'comfortable_seating')::boolean, v.comfortable_seating),
      cozy                = coalesce((new.payload->>'cozy')::boolean, v.cozy),
      quiet_space         = coalesce((new.payload->>'quiet_space')::boolean, v.quiet_space),
      neighbourhood       = coalesce(nullif(new.payload->>'neighbourhood',''), v.neighbourhood),
      last_confirmed_at   = now(),
      updated_at          = now()
    where v.id = new.venue_id;
  end if;
  return new;
end $$;

-- ---------- 2. Public photo gallery (verified submissions only) ----------
-- Exposes ONLY venue_id, the photo file and the date — nothing about who
-- submitted it.
create or replace view public.venue_photos as
  select venue_id, photo_path, verified_at
    from public.submissions
   where status = 'verified' and venue_id is not null;

grant select on public.venue_photos to anon, authenticated;
