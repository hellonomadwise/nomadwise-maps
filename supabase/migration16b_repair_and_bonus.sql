-- ============================================================
-- Nomadwise Maps — repair + migration 16 in one go
-- The discovered_places table was missing from the database, so
-- this first creates it, then adds the first-discoverer bonus.
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

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


-- 1. Remember who found each place (and whether they were paid).
alter table public.discovered_places
  add column if not exists discovered_by uuid references auth.users(id),
  add column if not exists bonus_paid boolean not null default false;

-- 2. Pay the finder when the space's review is verified.
create or replace function public.pay_discovery_bonus()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  dp record;
begin
  if new.status = 'verified' and old.status <> 'verified'
     and new.kind = 'new_venue' then
    select d.google_place_id, d.discovered_by into dp
      from public.venues v
      join public.discovered_places d
        on d.google_place_id = v.google_place_id
     where v.id = new.venue_id
       and d.discovered_by is not null
       and not d.bonus_paid
     limit 1;
    if found then
      insert into public.coin_ledger
        (user_id, submission_id, amount, status, note)
      values (dp.discovered_by, new.id, 10, 'withdrawable',
              'Discovery bonus: you put this space on the map first');
      update public.discovered_places
         set bonus_paid = true
       where google_place_id = dp.google_place_id;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_discovery_bonus on public.submissions;
create trigger trg_discovery_bonus
  after update on public.submissions
  for each row execute function public.pay_discovery_bonus();
