-- ============================================================
-- Nomadwise Maps — migration 34: city sweeps + smarter signals
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- 1. city_sweeps remembers which cities the nightly job has
--    already swept (proactive discovery of every cafe in town).
-- 2. signal_negative stores review mentions AGAINST working
--    there ("no laptops allowed") - such places never show as
--    promising, whatever else their reviews say.
-- ============================================================

create table if not exists public.city_sweeps (
  city         text primary key,
  center_lat   double precision,
  center_lng   double precision,
  places_found integer,
  swept_at     timestamptz not null default now()
);

alter table public.city_sweeps enable row level security;

drop policy if exists "admin reads city sweeps" on public.city_sweeps;
create policy "admin reads city sweeps" on public.city_sweeps
  for select using (public.is_admin());

alter table public.discovered_places
  add column if not exists signal_negative integer;

-- The queue the admin fills from the app ("Sweep a city" in the
-- menu). The overnight job takes one city per run.
create table if not exists public.sweep_queue (
  city         text primary key,
  requested_by uuid references auth.users(id),
  requested_at timestamptz not null default now()
);

alter table public.sweep_queue enable row level security;

drop policy if exists "admin manages sweep queue" on public.sweep_queue;
create policy "admin manages sweep queue" on public.sweep_queue
  for all using (public.is_admin()) with check (public.is_admin());

-- First city in the queue: Copenhagen, ready before the trip.
insert into public.sweep_queue (city) values ('Copenhagen')
on conflict do nothing;
