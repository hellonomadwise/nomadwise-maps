-- ============================================================
-- Migration 41 — stop holding WiFi passwords.
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- A venue's WiFi password is the venue's to share, not ours to
-- collect and redistribute. The app no longer collects or shows
-- passwords (it says "ask the staff" instead); this removes every
-- password already stored, from the live table and from old
-- submission payloads, so nothing sensitive remains at rest.
-- ============================================================

update public.venue_wifi set password = null where password is not null;

update public.submissions
   set payload = payload - 'password'
 where kind in ('wifi_login', 'new_venue', 'confirm')
   and payload ? 'password';
