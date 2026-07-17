-- ============================================================
-- Nomadwise Maps — migration 15: WiFi network fingerprinting
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- Everyone on a cafe's WiFi reaches the internet through the same
-- public address. Each WiFi test records an anonymous fingerprint
-- (a one-way hash, the raw address is never stored) of the network
-- it ran on. The first verified test at a space establishes that
-- space's fingerprint; later tests auto-verify only when they come
-- from a matching network. A test from a different network (e.g.
-- mobile data, or not actually there) is held for admin review.
-- ============================================================

create extension if not exists pgcrypto;

-- 1. The caller's network fingerprint (hashed, never the raw address).
create or replace function public.network_fingerprint()
returns text
language sql stable security definer
set search_path = public, extensions as
$$
  select encode(digest(
    coalesce(split_part(
      current_setting('request.headers', true)::json->>'x-forwarded-for',
      ',', 1), 'unknown') || '|nomadwise-v1',
    'sha256'), 'hex')
$$;

revoke all on function public.network_fingerprint() from public, anon;
grant execute on function public.network_fingerprint() to authenticated;

-- 2. Known networks per space.
create table if not exists public.venue_networks (
  venue_id     uuid not null references public.venues(id) on delete cascade,
  network_hash text not null,
  seen_count   integer not null default 1,
  first_seen   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  primary key (venue_id, network_hash)
);
alter table public.venue_networks enable row level security;
-- No policies on purpose: only the functions below (which run with
-- elevated rights) may read or write it.

-- 3. Auto-verify now checks the network for wifi tests.
create or replace function public.auto_verify_confirm()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  nh text;
  has_prints boolean;
  matches boolean;
begin
  if new.kind in ('confirm','wifi_test','wifi_login')
     and new.gps_distance_m is not null
     and new.gps_distance_m <= 150 then

    if new.kind = 'wifi_test' and new.venue_id is not null then
      nh := nullif(new.payload->>'network_hash','');
      select exists (select 1 from public.venue_networks vn
                      where vn.venue_id = new.venue_id)
        into has_prints;
      if has_prints then
        select exists (select 1 from public.venue_networks vn
                        where vn.venue_id = new.venue_id
                          and vn.network_hash = nh)
          into matches;
        if nh is null or not matches then
          -- Different network than every earlier test here:
          -- hold it for admin review instead of paying out.
          return new;
        end if;
      end if;
      -- First test here (or a match): fall through and verify.
    end if;

    update public.submissions
       set status = 'verified', verified_at = now()
     where id = new.id;
  end if;
  return new;
end $$;

-- 4. Every verified wifi test teaches us the space's network
--    (including ones an admin approves by hand).
create or replace function public.record_venue_network()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'verified' and old.status <> 'verified'
     and new.kind = 'wifi_test' and new.venue_id is not null
     and nullif(new.payload->>'network_hash','') is not null then
    insert into public.venue_networks (venue_id, network_hash)
    values (new.venue_id, new.payload->>'network_hash')
    on conflict (venue_id, network_hash) do update
      set seen_count = public.venue_networks.seen_count + 1,
          last_seen = now();
  end if;
  return new;
end $$;

drop trigger if exists trg_record_network on public.submissions;
create trigger trg_record_network
  after update on public.submissions
  for each row execute function public.record_venue_network();
