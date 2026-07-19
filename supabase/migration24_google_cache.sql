-- ============================================================
-- Nomadwise Maps — migration 24: cached Google details per venue
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- The daily build job stores each venue's Google details (rating,
-- opening hours, photo list) here. The app reads this copy instead
-- of asking Google on every map open, which is what was burning
-- through the Google Cloud credit.
-- ============================================================

alter table public.venues
  add column if not exists g_details  jsonb,
  add column if not exists g_synced_at timestamptz;
