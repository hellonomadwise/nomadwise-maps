-- ============================================================
-- Migration 62: Region and Location creators in the app.
-- (Applied automatically by the build; nothing to paste.)
--
-- The founder fills a short form in Nomad Maps (name, country or
-- region, map centre, optional description); the request lands here;
-- the push run creates the Webflow item the way the existing ones
-- are built (name, label, slug, category label, H2, map centre,
-- links to Country and Region), publishes it, wires the Region's
-- Locations list, copies it into the app's pickers and links every
-- space that was waiting for it. Nothing is created without a form
-- the founder filled in.
--
--   taxonomy_requests   one row per request, with the outcome
--   webflow_countries   copy of the Countries collection for the
--                       country picker (read by everyone)
-- ============================================================

create table if not exists public.taxonomy_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('region','location')),
  name text not null,
  country_id text,
  region_id text,
  lat double precision,
  lng double precision,
  zoom int,
  description text,
  venue_id uuid references public.venues(id) on delete set null,
  requested_by uuid,
  status text not null default 'pending'
    check (status in ('pending','created','failed')),
  webflow_id text,
  slug text,
  error text,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
alter table public.taxonomy_requests enable row level security;
drop policy if exists "admins manage taxonomy requests" on public.taxonomy_requests;
create policy "admins manage taxonomy requests" on public.taxonomy_requests
  for all using (public.is_admin()) with check (public.is_admin());

create table if not exists public.webflow_countries (
  id text primary key,
  name text not null,
  slug text,
  updated_at timestamptz not null default now()
);
alter table public.webflow_countries enable row level security;
drop policy if exists "countries readable by all" on public.webflow_countries;
create policy "countries readable by all" on public.webflow_countries
  for select using (true);

-- The GitHub nudge, shared by the venues trigger and this one.
create or replace function public.nudge_github()
returns void language plpgsql security definer set search_path = public as $$
declare
  tok text;
  last_nudge timestamptz;
begin
  select last_at into last_nudge from public.sync_nudges where id = 1 for update;
  if last_nudge is not null and last_nudge > now() - interval '2 minutes' then
    return;
  end if;
  select decrypted_secret into tok
    from vault.decrypted_secrets
   where name = 'github_actions_token'
   limit 1;
  if tok is null or tok = '' then
    return;
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
exception when others then
  null;
end $$;

create or replace function public.nudge_taxonomy_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.nudge_github();
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists trg_nudge_taxonomy_request on public.taxonomy_requests;
create trigger trg_nudge_taxonomy_request
  after insert on public.taxonomy_requests
  for each row execute function public.nudge_taxonomy_request();
