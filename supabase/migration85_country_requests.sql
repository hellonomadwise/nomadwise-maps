-- ============================================================
-- Migration 85: a Country (country page) can be created from the app.
-- (Applied automatically by the build; nothing to paste.)
--
-- The control centre's Create menu had Region and Location but not
-- the level above them, so a first space in a new country (Kopi
-- Club, Sri Lanka) had nowhere to go. Same request table, same sync.
-- ============================================================

alter table public.taxonomy_requests drop constraint if exists taxonomy_requests_kind_check;
alter table public.taxonomy_requests
  add constraint taxonomy_requests_kind_check
  check (kind in ('region','location','country','refresh'));
