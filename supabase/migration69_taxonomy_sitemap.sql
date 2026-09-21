-- ============================================================
-- Migration 69: region and location pages in the custom sitemap.
-- (Applied automatically by the build; nothing to paste.)
--
-- The directory pages — /region/<slug> and /locations/<slug> — are
-- where the traffic is: one page for a whole city or neighbourhood,
-- ranking for "coworking in X". A new one is worth far more than a
-- single listing, and until now nothing told the founders when one
-- had been created in Webflow but never added to the custom sitemap.
--
-- Same shape as venues.sitemap_added_at: the app lists what is
-- missing and generates the blocks to paste, and the nightly read of
-- the live sitemap in scripts/webflow_sync.py is the truth, marking
-- and unmarking rows so the list stays honest.
-- ============================================================

alter table public.webflow_regions
  add column if not exists sitemap_added_at timestamptz,
  add column if not exists first_seen_at timestamptz not null default now();

alter table public.webflow_locations
  add column if not exists sitemap_added_at timestamptz,
  add column if not exists first_seen_at timestamptz not null default now();

create index if not exists idx_webflow_regions_sitemap
  on public.webflow_regions(sitemap_added_at) where sitemap_added_at is null;
create index if not exists idx_webflow_locations_sitemap
  on public.webflow_locations(sitemap_added_at) where sitemap_added_at is null;

-- The founders tick items off, so admins need write access. Reading
-- stays open (the app's Region and Location pickers are public).
drop policy if exists "regions admin write" on public.webflow_regions;
create policy "regions admin write" on public.webflow_regions
  for update to authenticated using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "locations admin write" on public.webflow_locations;
create policy "locations admin write" on public.webflow_locations
  for update to authenticated using (public.is_admin())
  with check (public.is_admin());

-- Start from "already added" rather than showing several hundred
-- pages as missing on the first open. Tonight's read of the live
-- sitemap unmarks any that are genuinely absent, so within a day the
-- list is the real picture. (This is what migration 50 did for the
-- listing pages.)
update public.webflow_regions
   set sitemap_added_at = now()
 where sitemap_added_at is null;

update public.webflow_locations
   set sitemap_added_at = now()
 where sitemap_added_at is null;
