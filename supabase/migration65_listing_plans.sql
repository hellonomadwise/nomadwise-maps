-- ============================================================
-- Migration 65: listing plans (free or Verified) and the owner's
-- enquiry address.
-- (Applied automatically by the build; nothing to paste.)
--
-- A venue's listing_tier is the app's word on whether the page is a
-- paid Verified listing. Saving the plan in the control centre sets
-- listing_sync_requested_at; the push run then writes the Webflow
-- fields (Verified switch, Enquiries On switch, Listing Rank,
-- Enquiry Email) and republishes a live page, recording
-- listing_synced_at. The nightly pull copies the Webflow Verified
-- switch into webflow_verified so the app can show a mismatch (the
-- five legacy "premium" pages, say).
-- ============================================================

alter table public.venues
  add column if not exists listing_tier text not null default 'free',
  add column if not exists listing_paid_at date,
  add column if not exists listing_renews_at date,
  add column if not exists listing_owner_name text,
  add column if not exists listing_owner_email text,
  add column if not exists listing_enquiry_email text,
  add column if not exists listing_notes text,
  add column if not exists listing_sync_requested_at timestamptz,
  add column if not exists listing_synced_at timestamptz,
  add column if not exists listing_sync_error text,
  add column if not exists webflow_verified boolean,
  add column if not exists stripe_customer_id text,
  add column if not exists stripe_subscription_id text;

alter table public.venues drop constraint if exists venues_listing_tier_check;
alter table public.venues
  add constraint venues_listing_tier_check
  check (listing_tier in ('free','verified'));

create index if not exists idx_venues_listing_tier
  on public.venues(listing_tier) where listing_tier <> 'free';

-- The five pages that carried the old Premium switch start as Verified,
-- with the enquiry address the page already had where it was not the
-- default. No paid or renewal date is known for them; the founders
-- fill those in from the Listing plan form. The sync request makes
-- the push run write the fields so the page matches the plan.
update public.venues v set
  listing_tier = 'verified',
  listing_enquiry_email = case when v.webflow_cms_id = '67d78a0bd01eb8fd6ab57efe'
                               then 'info@sokkool.com' else v.listing_enquiry_email end,
  listing_notes = coalesce(v.listing_notes, 'Legacy premium page, marked Verified on 20 Sep 2026.'),
  listing_sync_requested_at = now(),
  listing_synced_at = null,
  webflow_verified = true
where v.webflow_cms_id in (
  '6809cff65b7d6598c8b425e1',   -- Lisbon-Cowork
  '67d78a0bd01eb8fd6ab57efe',   -- SOKKOOL Coliving & Coworking
  '67246a39070155fc18588f75',   -- ALTER SPACE Siargao Workspace
  '66d86b89956e2e75497bf514',   -- Ofis Voyvoda Istanbul
  '65fa86d0e0379bf78d52478d')   -- Monday
  and v.listing_tier = 'free';

-- The nudge trigger also wakes the push run for a listing plan save.
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
             and old.website_retire_requested_at is null)
         or (new.listing_sync_requested_at is not null
             and new.listing_sync_requested_at is distinct from old.listing_sync_requested_at));
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
