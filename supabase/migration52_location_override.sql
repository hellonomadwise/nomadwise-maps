-- ============================================================
-- Migration 52: founders choose the Location, never a guess alone.
-- (Applied automatically by the build; nothing to paste.)
--
-- A nomadwise.io page needs a Country and a Region (the city page);
-- a Location (the neighbourhood page) is optional and nuanced, so the
-- sync's guess is shown as a guess and the founder can change it or
-- drop it before approving. The Locations collection is copied
-- nightly, like Regions, so the app can offer the list.
-- ============================================================

alter table public.venues
  add column if not exists website_location_override text;
  -- a Webflow Location id, or the word 'none' for "no Location"

create table if not exists public.webflow_locations (
  id text primary key,
  name text not null,
  slug text,
  region_id text,
  country text,
  updated_at timestamptz not null default now()
);

alter table public.webflow_locations enable row level security;

drop policy if exists "locations readable by all" on public.webflow_locations;
create policy "locations readable by all" on public.webflow_locations
  for select using (true);
