-- ============================================================
-- Nomadwise Maps — migration 29: nomad signals on discovered pins
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- The nightly job reads each discovered place's Google reviews
-- once and stores how often they mention wifi / plugs / laptops.
-- The map then shows promising places as solid violet pins and
-- unknown ones as violet outlines.
-- ============================================================

alter table public.discovered_places
  add column if not exists signal_wifi   integer,
  add column if not exists signal_power  integer,
  add column if not exists signal_laptop integer,
  add column if not exists signals_checked_at timestamptz;
