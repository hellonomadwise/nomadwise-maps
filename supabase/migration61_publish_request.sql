-- ============================================================
-- Migration 61: "Publish on nomadwise.io" from the app.
-- (Applied automatically by the build; nothing to paste.)
--
-- The push run checks every Webflow draft (listing and Images entry
-- linked, slug as approved, Region, Country, at least three photos)
-- and stores the verdict in website_prepared.webflow_check. When the
-- founder taps Publish, website_publish_requested_at is set; the run
-- re-checks, stages both items and publishes them live through the
-- API, then marks the venue released. The nudge trigger wakes the run
-- for that request too.
-- ============================================================

alter table public.venues
  add column if not exists website_publish_requested_at timestamptz;

create or replace function public.nudge_website_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  tok text;
  last_nudge timestamptz;
  publish_asked boolean;
begin
  publish_asked := tg_op = 'UPDATE'
    and new.website_publish_requested_at is not null
    and old.website_publish_requested_at is null;
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
