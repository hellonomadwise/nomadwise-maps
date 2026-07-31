-- ============================================================
-- Migration 46 — opening hours stored in our own database.
-- (Applied automatically by the build; nothing to paste.)
--
-- The list view now answers "open now?" on every row. Asking Google
-- per row costs money at scale, so the nightly scanner saves each
-- place's weekly hours here (picked up for free during the review
-- scan it already does) and the app computes open/closed itself.
-- ============================================================

alter table public.discovered_places
  add column if not exists hours jsonb;
