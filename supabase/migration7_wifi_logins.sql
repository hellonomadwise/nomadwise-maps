-- ============================================================
-- Nomadwise Maps — migration 7: wifi logins (share for 20 coins)
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

-- 1. The current wifi login per venue
create table if not exists public.venue_wifi (
  venue_id    uuid primary key references public.venues(id) on delete cascade,
  ssid        text not null,
  password    text,                -- null = open network
  updated_by  uuid references auth.users(id),
  updated_at  timestamptz not null default now()
);

alter table public.venue_wifi enable row level security;

-- Signed-in users can read wifi logins (groundwork for premium gating later).
drop policy if exists "wifi readable by signed-in" on public.venue_wifi;
create policy "wifi readable by signed-in" on public.venue_wifi
  for select using (auth.role() = 'authenticated');
-- No direct writes: rows are created by the verification trigger below.

-- 2. New submission kind
alter table public.submissions drop constraint if exists submissions_kind_check;
alter table public.submissions add constraint submissions_kind_check
  check (kind in ('new_venue','confirm','wifi_test','wifi_login'));

-- 3. Coins: wifi login pays 20, once per space per user per 30 days
create or replace function public.award_coins_on_submission()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  amount integer;
  note_text text;
begin
  if new.kind = 'new_venue' then
    amount := 50; note_text := 'Space reviewed';
  elsif new.kind = 'wifi_test' then
    if exists (select 1 from public.submissions s
                where s.user_id = new.user_id and s.venue_id = new.venue_id
                  and s.kind = 'wifi_test' and s.id <> new.id
                  and s.created_at > now() - interval '30 days') then
      return new;
    end if;
    amount := 100; note_text := 'WiFi speed tested';
  elsif new.kind = 'wifi_login' then
    if exists (select 1 from public.submissions s
                where s.user_id = new.user_id and s.venue_id = new.venue_id
                  and s.kind = 'wifi_login' and s.id <> new.id
                  and s.created_at > now() - interval '30 days') then
      return new;
    end if;
    amount := 20; note_text := 'WiFi login shared';
  else
    amount := 30; note_text := 'Space confirmed/updated';
  end if;
  insert into public.coin_ledger (user_id, submission_id, amount, status, note)
  values (new.user_id, new.id, amount, 'pending', note_text);
  return new;
end $$;

-- 4. WiFi logins auto-verify with the GPS check
create or replace function public.auto_verify_confirm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind in ('confirm','wifi_test','wifi_login')
     and new.gps_distance_m is not null
     and new.gps_distance_m <= 150 then
    update public.submissions
       set status = 'verified', verified_at = now()
     where id = new.id;
  end if;
  return new;
end $$;

-- 5. Verified wifi logins land on the venue
create or replace function public.apply_wifi_login()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'verified' and old.status <> 'verified'
     and new.kind = 'wifi_login' and new.venue_id is not null
     and nullif(new.payload->>'ssid','') is not null then
    insert into public.venue_wifi (venue_id, ssid, password, updated_by, updated_at)
    values (new.venue_id,
            new.payload->>'ssid',
            nullif(new.payload->>'password',''),
            new.user_id,
            now())
    on conflict (venue_id) do update
      set ssid = excluded.ssid,
          password = excluded.password,
          updated_by = excluded.updated_by,
          updated_at = now();
  end if;
  return new;
end $$;

drop trigger if exists trg_apply_wifi_login on public.submissions;
create trigger trg_apply_wifi_login
  after update on public.submissions
  for each row execute function public.apply_wifi_login();
