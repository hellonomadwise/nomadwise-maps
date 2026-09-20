-- ============================================================
-- Migration 64: closed places and retiring their pages.
-- (Applied automatically by the build; nothing to paste.)
--
-- Google's business status is recorded for every venue by the nightly
-- run (the monthly snapshot carries it free; a cheap status-only check
-- covers the spaces with a page in between). A space seen as closed
-- shows up in the control centre's Closed section. The founder either
-- says "still open" (closed_dismissed_at) or retires the page
-- (website_retire_requested_at): the push run takes both CMS items off
-- the live site, archives them, releases the slug and adds a redirect
-- to the city page, then records website_retired_at and the note the
-- card shows. website_retire_done_at is the founder's own tick once
-- the sitemap entry is gone and the site published.
-- ============================================================

alter table public.venues
  add column if not exists business_status text,
  add column if not exists business_status_at timestamptz,
  add column if not exists closed_seen_at timestamptz,
  add column if not exists closed_dismissed_at timestamptz,
  add column if not exists website_retire_requested_at timestamptz,
  add column if not exists website_retired_at timestamptz,
  add column if not exists website_retire_note jsonb,
  add column if not exists website_retire_done_at timestamptz;

alter table public.venues drop constraint if exists venues_website_status_check;
alter table public.venues
  add constraint venues_website_status_check
  check (website_status in
    ('not_on_site','queued','published_hidden','released','removed','retired'));

create index if not exists idx_venues_closed_seen
  on public.venues(closed_seen_at) where closed_seen_at is not null;

-- The nudge trigger also wakes the push run for a retire request.
create or replace function public.nudge_website_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  tok text;
  last_nudge timestamptz;
  publish_asked boolean;
begin
  publish_asked := tg_op = 'UPDATE'
    and ((new.website_publish_requested_at is not null
          and old.website_publish_requested_at is null)
         or (new.website_retire_requested_at is not null
             and old.website_retire_requested_at is null));
  if not (new.website_status = 'queued' or new.website_approved_at is not null
          or publish_asked) then
    return new;
  end if;
  if tg_op = 'UPDATE' and not publish_asked then
    if old.website_photo_candidates is distinct from new.website_photo_candidates
       or old.google_photo_urls is distinct from new.google_photo_urls
       or (new.website_photos_auto and not coalesce(old.website_photos_auto, false))
       or (old.website_prepared is distinct from new.website_prepared
           and new.website_prepared is not null
           and old.website_approved_at is not distinct from new.website_approved_at
           and old.website_status = new.website_status)
    then
      return new;
    end if;
    if new.website_status = 'queued' and old.website_status = 'queued'
       and old.website_approved_at is not distinct from new.website_approved_at
       and old.website_region_override is not distinct from new.website_region_override
       and old.website_location_override is not distinct from new.website_location_override
       and old.website_slug_override is not distinct from new.website_slug_override
       and old.website_new_region is not distinct from new.website_new_region
       and old.website_new_location is not distinct from new.website_new_location
       and old.website_photos is not distinct from new.website_photos
       and old.country is not distinct from new.country
       and old.city is not distinct from new.city
       and old.neighbourhood is not distinct from new.neighbourhood
       and old.name is not distinct from new.name
    then
      return new;
    end if;
  end if;

  select last_at into last_nudge from public.sync_nudges where id = 1 for update;
  if last_nudge is not null and last_nudge > now() - interval '2 minutes' then
    return new;
  end if;

  select decrypted_secret into tok
    from vault.decrypted_secrets
   where name = 'github_actions_token'
   limit 1;
  if tok is null or tok = '' then
    return new;
  end if;

  perform net.http_post(
    url := 'https://api.github.com/repos/hellonomadwise/nomadwise-maps'
           '/actions/workflows/webflow_push.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || tok,
      'Accept', 'application/vnd.github+json',
      'Content-Type', 'application/json',
      'User-Agent', 'nomadmaps-db',
      'X-GitHub-Api-Version', '2022-11-28'));
  update public.sync_nudges set last_at = now() where id = 1;
  return new;
exception when others then
  return new;
end $$;
