-- ============================================================
-- Migration 49: the one-to-one link with nomadwise.io.
-- (Applied automatically by the build; nothing to paste.)
--
-- Every venue that has a page on nomadwise.io now stores the page's
-- slug (nomadwise.io/coworking/<slug>) and a website status, so the
-- app can link out to the site and the founders can see at a glance
-- which spaces are on the site, hidden, released or gone. The nightly
-- sync (scripts/webflow_sync.py) fills these from the live Webflow
-- collection; the shared key on both sides is the Google Place ID.
--
-- website_status values:
--   not_on_site      no Webflow item (community-added spaces)
--   queued           founders decided it should go to the site (phase 1)
--   published_hidden Webflow page exists but is kept out of the sitemap
--   released         page is live and in the sitemap (earns traffic)
--   removed          Webflow item archived, draft or deleted
-- ============================================================

alter table public.venues
  add column if not exists webflow_slug text,
  add column if not exists website_status text not null default 'not_on_site',
  add column if not exists website_synced_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'venues_website_status_check') then
    alter table public.venues
      add constraint venues_website_status_check
      check (website_status in
        ('not_on_site','queued','published_hidden','released','removed'));
  end if;
end $$;

create index if not exists idx_venues_webflow_cms_id
  on public.venues(webflow_cms_id);

create index if not exists idx_venues_webflow_slug
  on public.venues(webflow_slug);
