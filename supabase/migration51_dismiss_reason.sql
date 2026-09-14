-- ============================================================
-- Migration 51: why a space is not on nomadwise.io.
-- (Applied automatically by the build; nothing to paste.)
--
-- When a founder marks a space "Not for the site" in the control
-- centre, the reason is kept with it, so months later it is clear
-- why something is on Nomad Maps but not on nomadwise.io, and the
-- decision can be revisited when circumstances change.
-- ============================================================

alter table public.venues
  add column if not exists website_dismiss_reason text,
  add column if not exists website_dismiss_note text;
