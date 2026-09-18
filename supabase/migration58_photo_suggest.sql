-- ============================================================
-- Migration 58: photo suggestions for the website inbox.
-- (Applied automatically by the build; nothing to paste.)
--
-- scripts/photo_suggest.py lists a queued space's Google photos and
-- community photos, scores them against a written brief (show the
-- room, not the food) plus the founder's learned taste, and pre-fills
-- the page's five photos. The founder adjusts and approves.
--
--   venues.website_photo_candidates   scored list the app shows in
--                                     the picker; [] = looked, none
--   venues.website_photo_candidates_at when it was computed
--   venues.website_photos_auto        true while the five are the
--                                     script's suggestion, untouched
--   photo_embeddings                  one row per scored photo (for
--                                     learning); service role only
--   photo_picks                       what the founder kept and
--                                     skipped at Approve; written by
--                                     the app (admins), read nightly
--   sync_settings                     small key/value store for the
--                                     sync (the taste vector)
-- ============================================================

alter table public.venues
  add column if not exists website_photo_candidates jsonb,
  add column if not exists website_photo_candidates_at timestamptz,
  add column if not exists website_photos_auto boolean not null default false;

create table if not exists public.photo_embeddings (
  uri text primary key,
  venue_id uuid references public.venues(id) on delete cascade,
  embedding jsonb not null,
  label text,
  base real,
  created_at timestamptz not null default now()
);
alter table public.photo_embeddings enable row level security;

create table if not exists public.photo_picks (
  id bigserial primary key,
  venue_id uuid references public.venues(id) on delete cascade,
  uri text not null,
  source text,
  picked boolean not null,
  position int,
  score real,
  created_at timestamptz not null default now()
);
alter table public.photo_picks enable row level security;
drop policy if exists "admins record picks" on public.photo_picks;
create policy "admins record picks" on public.photo_picks
  for insert with check (public.is_admin());
drop policy if exists "admins read picks" on public.photo_picks;
create policy "admins read picks" on public.photo_picks
  for select using (public.is_admin());
create index if not exists idx_photo_picks_venue on public.photo_picks(venue_id);

create table if not exists public.sync_settings (
  key text primary key,
  value jsonb,
  updated_at timestamptz not null default now()
);
alter table public.sync_settings enable row level security;
