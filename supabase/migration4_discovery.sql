-- ============================================================
-- Nomadwise Maps — migration 4: cafe discovery + review coins
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- (Safe to run more than once.)
-- ============================================================

-- ---------- 1. Cache of Google-discovered places ----------
-- Filled progressively as users tap "Search this area" around the world.
create table if not exists public.discovered_places (
  google_place_id  text primary key,
  name             text not null,
  lat              double precision not null,
  lng              double precision not null,
  primary_type     text,
  rating           numeric,
  user_rating_count integer,
  fetched_at       timestamptz not null default now()
);

create index if not exists idx_discovered_lat_lng
  on public.discovered_places (lat, lng);

alter table public.discovered_places enable row level security;

drop policy if exists "discovered readable by all" on public.discovered_places;
create policy "discovered readable by all" on public.discovered_places
  for select using (true);

-- Anyone may add to the cache (it holds nothing sensitive — just what
-- Google already shows publicly on the map).
drop policy if exists "discovered insertable by all" on public.discovered_places;
create policy "discovered insertable by all" on public.discovered_places
  for insert with check (true);

drop policy if exists "discovered updatable by all" on public.discovered_places;
create policy "discovered updatable by all" on public.discovered_places
  for update using (true);

-- ---------- 2. Reviewing a space now earns 50 coins ----------
-- (was 100 when it was framed as "adding a new venue")
create or replace function public.award_coins_on_submission()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.coin_ledger (user_id, submission_id, amount, status, note)
  values (new.user_id, new.id,
          case when new.kind = 'new_venue' then 50 else 30 end,
          'pending',
          case when new.kind = 'new_venue' then 'Space reviewed' else 'Space confirmed/updated' end);
  return new;
end $$;
