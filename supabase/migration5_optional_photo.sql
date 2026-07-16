-- ============================================================
-- Nomadwise Maps — migration 5: photos become optional
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

-- 1. Submissions no longer require a photo
alter table public.submissions alter column photo_path drop not null;

-- 2. Auto-verify confirmations on the GPS check alone
--    (being physically at the venue is the real proof; photos are a bonus)
create or replace function public.auto_verify_confirm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'confirm'
     and new.gps_distance_m is not null
     and new.gps_distance_m <= 150 then
    update public.submissions
       set status = 'verified', verified_at = now()
     where id = new.id;
  end if;
  return new;
end $$;

-- 3. Photo gallery only lists submissions that actually have a photo
create or replace view public.venue_photos as
  select venue_id, photo_path, verified_at
    from public.submissions
   where status = 'verified'
     and venue_id is not null
     and photo_path is not null;

grant select on public.venue_photos to anon, authenticated;
