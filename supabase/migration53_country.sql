-- ============================================================
-- Migration 53: the country, spelled out on the venue.
-- (Applied automatically by the build; nothing to paste.)
--
-- nomadwise.io slugs are always country-region-name (for example
-- portugal-lisbon-lacs-anjos). The country comes from Google's address
-- unless a founder types it in the control centre's Edit page; either
-- way it is stored here so the slug is predictable and editable.
-- ============================================================

alter table public.venues
  add column if not exists country text;
