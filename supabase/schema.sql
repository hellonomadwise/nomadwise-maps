-- ============================================================
-- Nomadwise Maps — Supabase schema  (v1)
-- Paste this whole file into: Supabase → SQL Editor → New query → Run
-- ============================================================

-- ---------- VENUES ----------
create table if not exists public.venues (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  type             text not null check (type in ('cafe','coworking')),
  neighbourhood    text,
  city             text not null default 'Lisbon',
  google_place_id  text unique,
  lat              double precision,
  lng              double precision,
  -- Nomadwise work-friendliness fields (null = unknown, to be confirmed for coins)
  laptops_allowed  boolean,
  wifi_speed_mbps  numeric,
  power_outlets    boolean,
  aircon           boolean,
  comfortable_seating boolean,
  cozy             boolean,
  quiet_space      boolean,
  good_for_calls   boolean,
  call_room        boolean,
  monitor          boolean,
  office_chairs    boolean,
  access_24h       boolean,
  website          text,
  instagram        text,
  -- snapshot values from the CMS export (live values come from Google)
  google_rating_snapshot  numeric,
  google_reviews_snapshot integer,
  webflow_cms_id   text,
  -- fallback opening hours from the spreadsheet (Google is the live source)
  opening_hours    jsonb,
  photo_url        text,
  status           text not null default 'verified' check (status in ('pending','verified','rejected')),
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- ---------- USER PROFILES ----------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text,
  created_at    timestamptz not null default now()
);

-- auto-create a profile whenever a user signs up
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- SUBMISSIONS (add / confirm a venue) ----------
create table if not exists public.submissions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id),
  venue_id       uuid references public.venues(id),          -- null = brand-new venue
  kind           text not null check (kind in ('new_venue','confirm')),
  payload        jsonb not null,                              -- the submitted field values
  photo_path     text not null,                               -- required photo in storage
  gps_lat        double precision not null,                   -- where the user actually was
  gps_lng        double precision not null,
  gps_distance_m numeric,                                     -- distance from venue at submit time
  status         text not null default 'pending' check (status in ('pending','verified','rejected')),
  created_at     timestamptz not null default now(),
  verified_at    timestamptz
);

-- ---------- COIN LEDGER ----------
-- Every coin movement is one row; balance = sum. Coins start 'pending'
-- and become 'withdrawable' only when the submission is verified.
create table if not exists public.coin_ledger (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id),
  submission_id  uuid references public.submissions(id),
  amount         integer not null,               -- +100 new venue, +30 confirm, negative = cash-out
  status         text not null default 'pending' check (status in ('pending','withdrawable','paid_out','cancelled')),
  note           text,
  created_at     timestamptz not null default now()
);

create index if not exists idx_ledger_user on public.coin_ledger(user_id);
create index if not exists idx_venues_place on public.venues(google_place_id);
create index if not exists idx_submissions_user on public.submissions(user_id);

-- ---------- AUTOMATIC COIN AWARDS ----------
-- When a submission row is inserted -> award pending coins.
-- When it is marked verified        -> flip those coins to withdrawable.
create or replace function public.award_coins_on_submission()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.coin_ledger (user_id, submission_id, amount, status, note)
  values (new.user_id, new.id,
          case when new.kind = 'new_venue' then 100 else 30 end,
          'pending',
          case when new.kind = 'new_venue' then 'New venue added' else 'Venue confirmed/updated' end);
  return new;
end $$;

drop trigger if exists trg_award_coins on public.submissions;
create trigger trg_award_coins
  after insert on public.submissions
  for each row execute function public.award_coins_on_submission();

create or replace function public.release_coins_on_verify()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'verified' and old.status <> 'verified' then
    update public.coin_ledger set status = 'withdrawable'
      where submission_id = new.id and status = 'pending';
    -- if it was a new venue, publish it on the map
    if new.kind = 'new_venue' and new.venue_id is not null then
      update public.venues set status = 'verified' where id = new.venue_id;
    end if;
  elsif new.status = 'rejected' and old.status <> 'rejected' then
    update public.coin_ledger set status = 'cancelled'
      where submission_id = new.id and status = 'pending';
  end if;
  return new;
end $$;

drop trigger if exists trg_release_coins on public.submissions;
create trigger trg_release_coins
  after update on public.submissions
  for each row execute function public.release_coins_on_verify();

-- ---------- WALLET VIEW (one row per user, ready for the app) ----------
create or replace view public.wallet as
  select
    user_id,
    coalesce(sum(amount) filter (where status = 'withdrawable'), 0) as withdrawable,
    coalesce(sum(amount) filter (where status = 'pending'), 0)      as pending,
    coalesce(sum(amount) filter (where status in ('withdrawable','pending')), 0) as total
  from public.coin_ledger
  group by user_id;

-- ---------- ROW LEVEL SECURITY ----------
alter table public.venues       enable row level security;
alter table public.profiles     enable row level security;
alter table public.submissions  enable row level security;
alter table public.coin_ledger  enable row level security;

-- Everyone (even logged-out) can see verified venues on the map
create policy "venues readable by all" on public.venues
  for select using (status = 'verified' or created_by = auth.uid());

-- Logged-in users can add a pending venue
create policy "users can add pending venues" on public.venues
  for insert with check (auth.uid() = created_by and status = 'pending');

create policy "own profile read"  on public.profiles for select using (auth.uid() = id);
create policy "own profile write" on public.profiles for update using (auth.uid() = id);

create policy "own submissions read"   on public.submissions for select using (auth.uid() = user_id);
create policy "own submissions insert" on public.submissions for insert with check (auth.uid() = user_id);

create policy "own ledger read" on public.coin_ledger for select using (auth.uid() = user_id);

-- ---------- PHOTO STORAGE ----------
insert into storage.buckets (id, name, public)
values ('submission-photos','submission-photos', true)
on conflict (id) do nothing;

create policy "photo upload by owner" on storage.objects
  for insert with check (
    bucket_id = 'submission-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "photos readable" on storage.objects
  for select using (bucket_id = 'submission-photos');
