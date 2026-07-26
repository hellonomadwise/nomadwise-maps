-- ============================================================
-- Migration 40 — WiFi logins readable by everyone.
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- The recorded WiFi name and password of a cafe is the kind of
-- information written on a chalkboard by the till. Hiding it
-- behind login contradicted the app's purpose: reading is for
-- everyone, signing in is for contributing. Writes still happen
-- only through verified submissions.
-- ============================================================

drop policy if exists "wifi readable by signed-in" on public.venue_wifi;
create policy "wifi readable by everyone" on public.venue_wifi
  for select using (true);
