-- ============================================================
-- Nomadwise Maps — migration 63: "refresh from Webflow" request
-- Applied automatically by the build.
-- ============================================================

-- A request of kind 'refresh' asks the website sync to copy the
-- site's current Regions and Locations into the app's pickers. Same
-- table, same nudge, no Webflow item is created.
alter table public.taxonomy_requests
  drop constraint if exists taxonomy_requests_kind_check;
alter table public.taxonomy_requests
  add constraint taxonomy_requests_kind_check
  check (kind in ('region','location','refresh'));
