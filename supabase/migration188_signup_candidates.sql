-- ============================================================
-- Migration 188: sign-ups from the old forms, on the Candidates list.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 19 Oct 2026: the spaces that signed up through our old
-- forms.app forms and are not on nomadwise.io yet should be "a list,
-- added to the candidates list, with all the relevant info from the
-- form submission", and "next on the list to review". They asked to
-- be listed, so they come before the places the nightly job found.
--
-- A sign-up is not a Google place yet: the form gave a name and an
-- address, not a place id. So a sign-up has its own small table. On
-- its card a founder finds the place on Google, checks it, and queues
-- it; from there it is a space like any candidate (Queued, Ready to
-- approve, In Webflow), and nothing reaches Webflow without Approve.
-- Or "Not for the site", with a reason, as for any candidate.
--
-- The rows themselves (names, emails, phone numbers) are NOT in this
-- file: people's details do not belong in the code repository. They
-- are added once in the Supabase SQL editor from a file kept outside
-- it. This file only makes the table and the three calls.
--
-- Safe to apply twice. Nothing existing is changed.
-- ============================================================

create table if not exists public.candidate_signups (
  id             uuid primary key default gen_random_uuid(),
  sort           integer not null default 100,
  form           text,
  submitted_at   timestamptz,
  name           text not null,
  kind           text not null default 'coworking'
                   check (kind in ('coworking', 'cafe', 'coliving')),
  address        text,
  area           text,
  city           text,
  country        text,
  website        text,
  instagram      text,
  contact_name   text,
  contact_email  text,
  contact_phone  text,
  features       text,
  wifi_mbps      numeric,
  prices         text,
  history        text,
  flag           text,
  status         text not null default 'open'
                   check (status in ('open', 'queued', 'dismissed')),
  reason         text,
  google_place_id text,
  venue_id       uuid references public.venues(id) on delete set null,
  decided_by     uuid references auth.users(id),
  decided_at     timestamptz,
  created_at     timestamptz not null default now()
);

-- Adding the same sign-up twice changes nothing.
create unique index if not exists candidate_signups_once
  on public.candidate_signups (lower(name), lower(coalesce(contact_email, '')));

alter table public.candidate_signups enable row level security;

drop policy if exists "admin manages candidate signups"
  on public.candidate_signups;
create policy "admin manages candidate signups"
  on public.candidate_signups
  for all using (public.is_admin()) with check (public.is_admin());

-- 1. The open sign-ups, in the order to look at them.
create or replace function public.admin_candidate_signups()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(s) order by s.sort, s.submitted_at desc nulls last)
      from public.candidate_signups s
     where s.status = 'open'), '[]'::jsonb);
end $$;
revoke all on function public.admin_candidate_signups() from public, anon;
grant execute on function public.admin_candidate_signups() to authenticated;

-- 2. Queue a sign-up for the site, once its Google place is found.
--    p carries what Google said for that place just now: name, lat,
--    lng, rating, reviews, city and country (the city as the site
--    spells it when it has a page for it), website.
create or replace function public.candidate_signup_queue(
  p_id uuid, p_place text, p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s      public.candidate_signups%rowtype;
  v_id   uuid;
  v_name text;
  v_city text;
  v_lat  double precision;
  v_lng  double precision;
  near   record;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  select * into s from public.candidate_signups where id = p_id;
  if not found then
    raise exception 'That sign-up is no longer on the list.';
  end if;
  if nullif(trim(coalesce(p_place, '')), '') is null then
    raise exception 'Find the place on Google first.';
  end if;

  -- Already a space with this Google place: link it, change nothing.
  select id, name into v_id, v_name
    from public.venues where google_place_id = p_place;
  if v_id is not null then
    update public.candidate_signups
       set status = 'queued', google_place_id = p_place, venue_id = v_id,
           decided_by = auth.uid(), decided_at = now()
     where id = p_id;
    return jsonb_build_object('venue_id', v_id, 'name', v_name,
                              'existed', true);
  end if;

  v_lat := nullif(p->>'lat', '')::double precision;
  v_lng := nullif(p->>'lng', '')::double precision;
  if v_lat is null or v_lng is null then
    raise exception 'Google gave no location for that place.';
  end if;
  select * into near from public.candidate_region(v_lat, v_lng);

  v_name := public.tidy_space_name(coalesce(
    nullif(left(trim(coalesce(p->>'name', '')), 200), ''), s.name));
  v_city := coalesce(
    nullif(left(trim(coalesce(p->>'city', '')), 120), ''),
    near.region_name,
    nullif(trim(coalesce(s.city, '')), ''),
    'Unknown');

  insert into public.venues (
    name, type, city, country, website, google_place_id, lat, lng,
    google_rating_snapshot, google_reviews_snapshot,
    status, website_status, source, created_by)
  values (
    v_name,
    s.kind,
    v_city,
    coalesce(nullif(left(trim(coalesce(p->>'country', '')), 120), ''),
             near.region_country,
             nullif(trim(coalesce(s.country, '')), '')),
    coalesce(nullif(left(trim(coalesce(s.website, '')), 300), ''),
             nullif(left(trim(coalesce(p->>'website', '')), 300), '')),
    p_place,
    v_lat,
    v_lng,
    nullif(p->>'rating', '')::numeric,
    nullif(p->>'reviews', '')::integer,
    'verified',
    'queued',
    'signup',
    auth.uid())
  returning id into v_id;

  -- So the nightly list never offers the same place again.
  insert into public.candidate_decisions
    (google_place_id, decision, name, venue_id, decided_by)
  values (p_place, 'queued', v_name, v_id, auth.uid())
  on conflict (google_place_id) do update
     set decision = 'queued',
         venue_id = excluded.venue_id,
         reason = null,
         note = null,
         decided_by = excluded.decided_by,
         decided_at = now();

  update public.candidate_signups
     set status = 'queued', google_place_id = p_place, venue_id = v_id,
         decided_by = auth.uid(), decided_at = now()
   where id = p_id;

  return jsonb_build_object('venue_id', v_id, 'name', v_name,
                            'city', v_city, 'existed', false);
end $$;
revoke all on function public.candidate_signup_queue(uuid, text, jsonb) from public, anon;
grant execute on function public.candidate_signup_queue(uuid, text, jsonb) to authenticated;

-- 3. Not for the site, with the reason; kept, never deleted.
create or replace function public.candidate_signup_dismiss(
  p_id uuid, p_reason text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  update public.candidate_signups
     set status = 'dismissed',
         reason = left(trim(coalesce(p_reason, '')) ||
                       case when nullif(trim(coalesce(p_note, '')), '') is null
                            then '' else ': ' || trim(p_note) end, 300),
         decided_by = auth.uid(), decided_at = now()
   where id = p_id;
end $$;
revoke all on function public.candidate_signup_dismiss(uuid, text, text) from public, anon;
grant execute on function public.candidate_signup_dismiss(uuid, text, text) to authenticated;
