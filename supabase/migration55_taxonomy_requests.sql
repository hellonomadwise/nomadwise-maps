-- ============================================================
-- Migration 55: asking for a Region or Location, never inventing one.
-- (Applied automatically by the build; nothing to paste.)
--
-- The site's Regions (city pages) and Locations (neighbourhood pages)
-- are the founders' taxonomy and only they create them, in Webflow.
-- When a space belongs somewhere that does not exist yet, the founder
-- records the name they want here; the space waits under Blocked, and
-- the moment the nightly copy sees a Region or Location with exactly
-- that name, the sync links the space to it and clears the request.
-- ============================================================

alter table public.venues
  add column if not exists website_new_region text,
  add column if not exists website_new_location text;
