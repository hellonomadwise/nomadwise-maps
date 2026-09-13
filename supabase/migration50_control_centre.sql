-- ============================================================
-- Migration 50: the Website control centre (inbox for the site).
-- (Applied automatically by the build; nothing to paste.)
--
-- Queueing a space for nomadwise.io no longer creates the Webflow
-- draft straight away. The nightly sync now PREPARES a proposal
-- first (slug, region, location, type, hours, facts, photo count)
-- and stores it here; the founders see it in the app's inbox, fix
-- what needs fixing, and tap Approve. Only approved spaces get a
-- Webflow item on the next run, so the slug is seen before it is
-- born and never needs renaming (a rename would need a redirect).
--
-- Columns on venues:
--   website_prepared        the proposal, as JSON, or {"error": ...}
--                           when the sync could not find a Region
--   website_prepared_at     when it was last prepared
--   website_approved_at     set by the founder; cleared once created
--   website_dismissed_at    "not for the site": keeps the space out
--                           of the inbox without changing its status
--   website_region_override the Webflow Region the founder picked
--                           when the automatic match failed
--   website_slug_override   a slug the founder typed before creation
--   sitemap_added_at        when the page's entry went into the
--                           custom sitemap (the Sitemap tab lists the
--                           released pages that still lack one)
--
-- webflow_regions is a nightly copy of the Webflow Regions
-- collection so the app can offer a dropdown when a Region is
-- missing. Read by everyone, written by the sync only.
-- ============================================================

alter table public.venues
  add column if not exists website_prepared jsonb,
  add column if not exists website_prepared_at timestamptz,
  add column if not exists website_approved_at timestamptz,
  add column if not exists website_dismissed_at timestamptz,
  add column if not exists website_region_override text,
  add column if not exists website_slug_override text,
  add column if not exists sitemap_added_at timestamptz;

create table if not exists public.webflow_regions (
  id text primary key,
  name text not null,
  slug text,
  country text,
  updated_at timestamptz not null default now()
);

alter table public.webflow_regions enable row level security;

drop policy if exists "regions readable by all" on public.webflow_regions;
create policy "regions readable by all" on public.webflow_regions
  for select using (true);

-- Every page released today is already in the custom sitemap, bar
-- one the founders are adding by hand (checked 13 Sep 2026).
update public.venues
   set sitemap_added_at = now()
 where website_status = 'released'
   and sitemap_added_at is null
   and webflow_slug is distinct from
       'italy-florence-ditta-artigianale-riva-darno';

create index if not exists idx_venues_website_inbox
  on public.venues(website_status, website_dismissed_at);
