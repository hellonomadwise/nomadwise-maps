-- ============================================================
-- Migration 74: the app can flag a venue whose Google photos died.
-- (Applied automatically by the build; nothing to paste.)
--
-- Google photo names, and the plain links made from them, stop
-- working about four weeks after they are issued. When the app finds
-- a venue's photos broken it fetches fresh ones for that session and
-- calls this, which puts the venue at the front of the nightly
-- refresh so everyone gets working photos (and free plain links)
-- from the next morning. Guarded so it cannot be used to force a
-- refresh of a venue that was refreshed recently.
-- ============================================================

create or replace function public.report_stale_photos(p_venue uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.venues
     set g_synced_at = null
   where id = p_venue
     and (g_synced_at is null or g_synced_at < now() - interval '7 days');
end $$;
grant execute on function public.report_stale_photos(uuid) to anon, authenticated;
