-- ============================================================
-- Migration 90: a daily spending limit on Google lookups, and phone
-- pings before and when it (or the map-load cap) is reached.
-- (Applied automatically by the build; nothing to paste.)
--
-- Every Google call is counted per day (api_usage, migration 89).
-- Here each count gets Google's list price, so today's spend can be
-- estimated at any moment. When the estimate for lookups reaches the
-- daily limit (£10 to start), the app and the jobs stop asking Google
-- until midnight UTC; visitors keep everything already stored.
--
-- The estimate uses list prices and ignores Google's free monthly
-- allowance, so it runs high: the real bill is lower, never higher.
--
-- Map loads are capped by Google itself (Maps JavaScript API, "Map
-- loads per day", set in Google Cloud to match map_loads_per_day
-- below). The app counts its own map loads, so the phone is pinged at
-- 80% and at the cap, and knows before visitors notice.
--
-- Phone pings (the usual ntfy topic), once per day each:
--   lookups at half the limit, lookups at the limit (paused),
--   map loads at 80% of the cap, map loads at the cap.
--
-- To change a limit: update public.api_limits set value = ... where
-- key = 'places_gbp_per_day' (or 'map_loads_per_day').
-- ============================================================

create table if not exists public.api_limits (
  key text primary key,
  value numeric not null
);
insert into public.api_limits (key, value) values
  ('places_gbp_per_day', 10),
  ('map_loads_per_day', 2300),
  ('usd_to_gbp', 0.75)
on conflict (key) do nothing;

alter table public.api_limits enable row level security;
drop policy if exists api_limits_admin_read on public.api_limits;
create policy api_limits_admin_read on public.api_limits
  for select using (public.is_admin());

create table if not exists public.api_usage_alerts (
  day date not null,
  kind text not null,
  sent_at timestamptz not null default now(),
  primary key (day, kind)
);
alter table public.api_usage_alerts enable row level security;
drop policy if exists api_usage_alerts_admin_read on public.api_usage_alerts;
create policy api_usage_alerts_admin_read on public.api_usage_alerts
  for select using (public.is_admin());

-- Google's list price per 1,000 calls in US dollars (pay as you go,
-- first volume tier, 2026). Lines not listed count as free.
create or replace function public.api_list_price_usd(p_sku text)
returns numeric language sql immutable as $$
  select case p_sku
    when 'Place Details Essentials (IDs Only)' then 0
    when 'Place Details Essentials' then 5
    when 'Place Details Pro' then 17
    when 'Place Details Enterprise' then 20
    when 'Place Details Enterprise + Atmosphere' then 25
    when 'Place Details Photos' then 7
    when 'Text Search Essentials (IDs Only)' then 0
    when 'Text Search Pro' then 32
    when 'Text Search Enterprise' then 35
    when 'Text Search Enterprise + Atmosphere' then 40
    when 'Nearby Search Pro' then 32
    when 'Nearby Search Enterprise' then 35
    when 'Nearby Search Enterprise + Atmosphere' then 40
    when 'Autocomplete Requests' then 2.83
    when 'Dynamic Maps' then 7
    else 0 end
$$;

-- Today's position: estimated £ on lookups, the limit, map loads.
create or replace function public.google_budget()
returns jsonb language sql stable security definer set search_path = public as $$
  with lim as (
    select
      coalesce((select value from api_limits where key = 'places_gbp_per_day'), 10) as gbp,
      coalesce((select value from api_limits where key = 'map_loads_per_day'), 2300) as maps,
      coalesce((select value from api_limits where key = 'usd_to_gbp'), 0.75) as fx
  ), today as (
    select
      coalesce(sum(case when sku <> 'Dynamic Maps'
                        then calls * api_list_price_usd(sku) / 1000.0 end), 0) as usd,
      coalesce(sum(case when sku = 'Dynamic Maps' then calls end), 0) as map_loads
    from api_usage
    where day = (now() at time zone 'utc')::date
  )
  select jsonb_build_object(
    'spent_gbp', round((today.usd * lim.fx)::numeric, 2),
    'limit_gbp', lim.gbp,
    'over', today.usd * lim.fx >= lim.gbp,
    'map_loads', today.map_loads,
    'map_cap', lim.maps,
    'fx', lim.fx)
  from lim, today
$$;

revoke all on function public.google_budget() from public;
grant execute on function public.google_budget() to anon, authenticated, service_role;

-- One ping per kind per day.
create or replace function public.api_alert_once(p_kind text, p_title text, p_msg text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into api_usage_alerts (day, kind)
  values ((now() at time zone 'utc')::date, p_kind);
  perform notify_phone(p_title, p_msg, 'warning');
exception when unique_violation then
  null; -- already sent today
end $$;

create or replace function public.check_api_alerts()
returns void language plpgsql security definer set search_path = public as $$
declare
  b jsonb := google_budget();
  spent numeric := (b->>'spent_gbp')::numeric;
  lim numeric := (b->>'limit_gbp')::numeric;
  loads numeric := (b->>'map_loads')::numeric;
  cap numeric := (b->>'map_cap')::numeric;
begin
  if spent >= lim then
    perform api_alert_once('places_limit', 'Google lookups paused',
      format('Today''s Google lookups reached about £%s, the daily limit of £%s (list prices). '
             'The app and nightly jobs stop asking Google until midnight UTC. '
             'Control centre, Analytics, Google calls shows which job or feature.', spent, lim));
  elsif spent >= lim / 2 then
    perform api_alert_once('places_half', 'Google lookups at half the daily limit',
      format('About £%s of the £%s daily limit used today (list prices). '
             'Control centre, Analytics, Google calls shows where.', spent, lim));
  end if;
  if loads >= cap then
    perform api_alert_once('maps_cap', 'Map loads at the daily cap',
      format('%s map loads today, the cap of %s. Google stops drawing the map until '
             'midnight Pacific time. Raise it in Google Cloud, Google Maps Platform, Quotas, '
             'Maps JavaScript API, Map loads per day.', loads, cap));
  elsif loads >= cap * 0.8 then
    perform api_alert_once('maps_80', 'Map loads at 80% of the daily cap',
      format('%s of %s map loads used today. If this is real traffic, raise the cap in '
             'Google Cloud before it runs out.', loads, cap));
  end if;
exception when others then
  null; -- alerts never break counting
end $$;

-- Counting now also accepts map loads, and checks the alerts after
-- every tally.
create or replace function public.record_api_usage(
  p_day date, p_source text, p_counts jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  k text;
  v jsonb;
  src text := left(coalesce(p_source, 'unknown'), 40);
  cap integer := 1000000;
begin
  if jsonb_typeof(coalesce(p_counts, 'null'::jsonb)) <> 'object' then
    return;
  end if;
  if coalesce(auth.role(), '') <> 'service_role' then
    src := 'app';
    cap := 500;
  end if;
  for k, v in select key, value from jsonb_each(p_counts) limit 30 loop
    if k !~ '^(Place Details|Text Search|Nearby Search|Autocomplete|Dynamic Maps)' then
      continue;
    end if;
    insert into public.api_usage as u (day, source, sku, calls, errors)
    values (coalesce(p_day, (now() at time zone 'utc')::date), src, left(k, 60),
            least(greatest(coalesce((v->>'calls')::int, 0), 0), cap),
            least(greatest(coalesce((v->>'errors')::int, 0), 0), cap))
    on conflict (day, source, sku) do update
       set calls = u.calls + excluded.calls,
           errors = u.errors + excluded.errors;
  end loop;
  perform check_api_alerts();
exception when others then
  return;
end $$;

revoke all on function public.record_api_usage(date, text, jsonb) from public;
grant execute on function public.record_api_usage(date, text, jsonb)
  to anon, authenticated, service_role;
