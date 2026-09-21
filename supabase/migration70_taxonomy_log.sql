-- ============================================================
-- Migration 70: the sitemap list becomes a log of what was set up.
-- (Applied automatically by the build; nothing to paste.)
--
-- Migration 69 compared every region and location against the live
-- sitemap, which treats a page made two years ago the same as one
-- made yesterday. The work is not "everything that has ever been
-- missing", it is "these were set up recently, are they in yet".
--
-- So the list is now a log. Every region, location and country the
-- sync sees for the first time from here on is logged with when it
-- appeared and where it came from (the app's creator, or made by hand
-- in Webflow), and stays on the list until its sitemap entry exists.
-- Everything that existed before today is marked untracked and never
-- appears, so the log starts clean.
--
-- The one-off sweep of older pages that were quietly missed is a
-- separate job for later; when it is wanted, it is one statement:
--   update public.webflow_regions set sitemap_tracked = true where id is not null;
-- and the nightly check does the rest.
-- ============================================================

alter table public.webflow_countries
  add column if not exists sitemap_added_at timestamptz,
  add column if not exists first_seen_at timestamptz not null default now();

alter table public.webflow_regions
  add column if not exists source text not null default 'webflow',
  add column if not exists sitemap_tracked boolean not null default true;

alter table public.webflow_locations
  add column if not exists source text not null default 'webflow',
  add column if not exists sitemap_tracked boolean not null default true;

alter table public.webflow_countries
  add column if not exists source text not null default 'webflow',
  add column if not exists sitemap_tracked boolean not null default true;

create index if not exists idx_webflow_countries_sitemap
  on public.webflow_countries(sitemap_added_at) where sitemap_added_at is null;

-- Countries are ticked off by the founders too.
drop policy if exists "countries admin write" on public.webflow_countries;
create policy "countries admin write" on public.webflow_countries
  for update to authenticated using (public.is_admin())
  with check (public.is_admin());

-- The log starts now: everything already here is left alone.
update public.webflow_regions
   set sitemap_tracked = false,
       sitemap_added_at = coalesce(sitemap_added_at, now())
 where id is not null;  -- Supabase refuses an update without a where

update public.webflow_locations
   set sitemap_tracked = false,
       sitemap_added_at = coalesce(sitemap_added_at, now())
 where id is not null;  -- Supabase refuses an update without a where

update public.webflow_countries
   set sitemap_tracked = false,
       sitemap_added_at = coalesce(sitemap_added_at, now())
 where id is not null;  -- Supabase refuses an update without a where
