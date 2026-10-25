-- ============================================================
-- Migration 224: Publish always starts the website push.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 25 Oct 2026: "this takes too long to make it so I can
-- publish a new space". Publish on nomadwise.io can now be pressed
-- before the draft check shows (the run checks first), so the press
-- must never be held back by the one-minute throttle: like an
-- approval, it always starts the run. GitHub serialises the runs
-- (concurrency group), so an extra start costs nothing.
-- Same as migration 76 otherwise. Pure ASCII, safe to run twice.
-- ============================================================

create or replace function public.nudge_website_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  tok text;
  last_nudge timestamptz;
  approval boolean;
  publish_asked boolean;
begin
  -- Only changes that give the push run something to do.
  if not (new.website_status = 'queued' or new.website_approved_at is not null) then
    return new;
  end if;
  approval := tg_op = 'UPDATE'
              and new.website_approved_at is not null
              and old.website_approved_at is distinct from new.website_approved_at;
  -- Publish pressed in the control centre (migration 61 had this; 76
  -- left it to the one-minute throttle).
  publish_asked := tg_op = 'UPDATE'
              and new.website_publish_requested_at is not null
              and old.website_publish_requested_at is null;
  if tg_op = 'UPDATE' and new.website_status = 'queued'
     and old.website_status = 'queued'
     and old.website_approved_at is not distinct from new.website_approved_at
     and old.website_region_override is not distinct from new.website_region_override
     and old.website_location_override is not distinct from new.website_location_override
     and old.website_slug_override is not distinct from new.website_slug_override
     and old.website_new_region is not distinct from new.website_new_region
     and old.website_new_location is not distinct from new.website_new_location
     and old.website_photos is not distinct from new.website_photos
     and old.website_prepared is not distinct from new.website_prepared
     and old.country is not distinct from new.country
     and old.city is not distinct from new.city
     and old.neighbourhood is not distinct from new.neighbourhood
     and old.name is not distinct from new.name
  then
    return new;
  end if;
  -- The sync's own writes (proposal saved) must not start another run.
  if tg_op = 'UPDATE' and old.website_prepared is distinct from new.website_prepared
     and new.website_prepared is not null
     and old.website_approved_at is not distinct from new.website_approved_at
     and old.website_status = new.website_status
  then
    return new;
  end if;

  select last_at into last_nudge from public.sync_nudges where id = 1 for update;
  if not (approval or publish_asked) and last_nudge is not null
     and last_nudge > now() - interval '1 minute' then
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
  return new; -- a nudge is best-effort; the schedule still runs
end $$;
