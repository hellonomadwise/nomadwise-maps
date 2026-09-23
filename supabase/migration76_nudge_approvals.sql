-- ============================================================
-- Migration 76: an approval always starts the website push.
-- (Applied automatically by the build; nothing to paste.)
--
-- Why: the nudge that starts the push run on GitHub was throttled to
-- one every two minutes. Queue a space, then approve it a minute
-- later, and the approval's nudge was dropped; the "every ten
-- minutes" schedule on GitHub actually fires every two to five
-- hours, so the approved space sat in "In Webflow" for hours
-- (23 Sep, sol - specialty coffee nanoroaster). Now an approval is
-- never throttled, and the throttle for everything else is one
-- minute. GitHub serialises the runs (concurrency group), so an
-- extra dispatch costs nothing.
-- ============================================================

create or replace function public.nudge_website_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  tok text;
  last_nudge timestamptz;
  approval boolean;
begin
  -- Only changes that give the push run something to do.
  if not (new.website_status = 'queued' or new.website_approved_at is not null) then
    return new;
  end if;
  approval := tg_op = 'UPDATE'
              and new.website_approved_at is not null
              and old.website_approved_at is distinct from new.website_approved_at;
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
  if not approval and last_nudge is not null
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

-- A button in the control centre for when a space is still waiting:
-- starts the push run on GitHub straight away, founders only.
create or replace function public.request_website_push()
returns text language plpgsql security definer set search_path = public as $$
declare
  tok text;
begin
  if not public.is_admin() then
    raise exception 'founders only';
  end if;
  select decrypted_secret into tok
    from vault.decrypted_secrets
   where name = 'github_actions_token'
   limit 1;
  if tok is null or tok = '' then
    return 'no_token';
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
  return 'requested';
end $$;
revoke execute on function public.request_website_push() from public, anon;
grant execute on function public.request_website_push() to authenticated;
