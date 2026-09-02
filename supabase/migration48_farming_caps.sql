-- ============================================================
-- Migration 48: farming caps (agreed by both founders, 8 Aug 2026).
-- (Applied automatically by the build; nothing to paste.)
--
-- Principle: coins pay for NEW information, never repeated actions.
-- WiFi tests and wifi shares already had 30-day cooldowns; this adds
-- the missing pieces: confirms get the same 30-day cooldown, wifi
-- shares tighten to once ever (a network name is one fact), a daily
-- ceiling of 300 coins per person, and duplicate submissions within
-- ten minutes stop ringing the founders' phones. Repeats are always
-- accepted and still update the space; they just award nothing.
-- Still to come in the app (phase 2): honest button copy inside
-- cooldowns, and the 100 euro monthly payout pool at cash-out time.
-- ============================================================

-- 1. The award rules, now complete.
create or replace function public.award_coins_on_submission()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_amount integer;
  v_note text;
  v_today integer;
begin
  if new.kind = 'new_venue' then
    v_amount := 50; v_note := 'Space reviewed';
  elsif new.kind = 'wifi_test' then
    -- One paid test per person per space per 30 days.
    if exists (select 1 from public.submissions s
                where s.user_id = new.user_id and s.venue_id = new.venue_id
                  and s.kind = 'wifi_test' and s.id <> new.id
                  and s.created_at > now() - interval '30 days') then
      return new;
    end if;
    v_amount := 100; v_note := 'WiFi speed tested';
  elsif new.kind = 'wifi_login' then
    -- A network name is one fact: pays once ever per person per space.
    if exists (select 1 from public.submissions s
                where s.user_id = new.user_id and s.venue_id = new.venue_id
                  and s.kind = 'wifi_login' and s.id <> new.id) then
      return new;
    end if;
    v_amount := 20; v_note := 'WiFi login shared';
  else
    -- Confirms: one paid confirm per person per space per 30 days.
    if exists (select 1 from public.submissions s
                where s.user_id = new.user_id and s.venue_id = new.venue_id
                  and s.kind = new.kind and s.id <> new.id
                  and s.created_at > now() - interval '30 days') then
      return new;
    end if;
    v_amount := 30; v_note := 'Space confirmed/updated';
  end if;

  -- Daily ceiling: 300 coins per person per day. The busiest honest
  -- day fits under it; grinding one street does not.
  select coalesce(sum(l.amount), 0) into v_today
    from public.coin_ledger l
   where l.user_id = new.user_id
     and l.amount > 0
     and l.status <> 'cancelled'
     and l.created_at > now() - interval '24 hours';
  if v_today + v_amount > 300 then
    return new;
  end if;

  insert into public.coin_ledger (user_id, submission_id, amount, status, note)
  values (new.user_id, new.id, v_amount, 'pending', v_note);
  return new;
end $$;

-- 2. Duplicate submissions within ten minutes stop pinging the phone
--    (they already earn nothing; now they are quiet too).
create or replace function public.notify_submission()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  who text;
  space text;
begin
  if public.is_team_member(new.user_id) then return new; end if;
  if exists (select 1 from public.submissions s
              where s.user_id = new.user_id
                and s.venue_id is not distinct from new.venue_id
                and s.kind = new.kind and s.id <> new.id
                and s.created_at > now() - interval '10 minutes') then
    return new;
  end if;
  select coalesce(nullif(display_name, ''), 'A nomad') into who
    from public.profiles where id = new.user_id;
  space := coalesce(
    (select name from public.venues where id = new.venue_id),
    new.payload->>'name', 'a space');
  perform public.notify_phone(
    case when new.kind = 'new_venue'
         then 'New space submitted' else 'New review' end,
    coalesce(who, 'A nomad') || ' -> ' || space,
    'tada');
  return new;
exception when others then
  return new;
end $$;
