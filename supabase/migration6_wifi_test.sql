-- ============================================================
-- Nomadwise Maps — migration 6: in-app wifi speed test (100 coins)
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

-- 1. New submission kind: wifi_test
alter table public.submissions drop constraint if exists submissions_kind_check;
alter table public.submissions add constraint submissions_kind_check
  check (kind in ('new_venue','confirm','wifi_test'));

-- 2. Coin awards: wifi test pays 100, but only once per space per user
--    per 30 days (re-tests are welcome, they just don't pay again).
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
                where s.user_id = new.user_id
                  and s.venue_id = new.venue_id
                  and s.kind = 'wifi_test'
                  and s.id <> new.id
                  and s.created_at > now() - interval '30 days') then
      return new; -- repeat test within 30 days: no coins
    end if;
    amount := 100; note_text := 'WiFi speed tested';
  else
    amount := 30; note_text := 'Space confirmed/updated';
  end if;
  insert into public.coin_ledger (user_id, submission_id, amount, status, note)
  values (new.user_id, new.id, amount, 'pending', note_text);
  return new;
end $$;

-- 3. WiFi tests auto-verify with the GPS check, like confirmations
create or replace function public.auto_verify_confirm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind in ('confirm','wifi_test')
     and new.gps_distance_m is not null
     and new.gps_distance_m <= 150 then
    update public.submissions
       set status = 'verified', verified_at = now()
     where id = new.id;
  end if;
  return new;
end $$;

-- 4. Verified wifi tests write the speed onto the venue
create or replace function public.apply_confirm_payload()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'verified' and old.status <> 'verified'
     and new.kind in ('confirm','wifi_test') and new.venue_id is not null then
    update public.venues v set
      laptops_allowed     = coalesce((new.payload->>'laptops_allowed')::boolean, v.laptops_allowed),
      wifi_speed_mbps     = coalesce((new.payload->>'wifi_speed_mbps')::numeric, v.wifi_speed_mbps),
      power_outlets       = coalesce((new.payload->>'power_outlets')::boolean, v.power_outlets),
      aircon              = coalesce((new.payload->>'aircon')::boolean, v.aircon),
      comfortable_seating = coalesce((new.payload->>'comfortable_seating')::boolean, v.comfortable_seating),
      cozy                = coalesce((new.payload->>'cozy')::boolean, v.cozy),
      quiet_space         = coalesce((new.payload->>'quiet_space')::boolean, v.quiet_space),
      neighbourhood       = coalesce(nullif(new.payload->>'neighbourhood',''), v.neighbourhood),
      last_confirmed_at   = now(),
      updated_at          = now()
    where v.id = new.venue_id;
  end if;
  return new;
end $$;
