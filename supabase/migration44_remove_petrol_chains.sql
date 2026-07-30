-- ============================================================
-- Migration 44 — petrol and convenience chains off the map.
-- (Applied automatically by the build; nothing to paste.)
--
-- Google types many Circle K petrol stations as cafes because they
-- sell coffee, so they were slipping onto the map as unscreened
-- "spaces". The app and the nightly scanner now refuse them at the
-- door; this removes any already cached, globally.
-- ============================================================

delete from public.discovered_places
 where name ~* 'circle\s*k\y'
    or primary_type in ('gas_station', 'convenience_store');
