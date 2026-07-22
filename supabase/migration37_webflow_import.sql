-- Migration 37 — Webflow import marker
-- Run in: Supabase -> SQL Editor -> New query -> paste -> Run
--
-- Adds a 'source' column so venues imported in bulk from the
-- nomadwise.io Webflow directory are permanently identifiable.
--
-- To UNDO the whole import later (removes only imported venues that
-- no user has contributed to):
--   delete from public.venues v
--    where v.source = 'nomadwise-webflow'
--      and not exists (select 1 from public.submissions s
--                       where s.venue_id = v.id);

alter table public.venues
  add column if not exists source text;

create index if not exists idx_venues_source on public.venues(source);
