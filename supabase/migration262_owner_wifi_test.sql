-- ============================================================
-- Migration 262: owners test their Wi-Fi at the space.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: a box to type the Wi-Fi speed invites "oh, it
-- is like 600". In the past he asked owners for a speedtest.net
-- screenshot, which adds friction. Agreed instead: a "Test your Wi-Fi"
-- button in the Owner account. The owner stands in the space on its
-- Wi-Fi, the app measures the speed itself (nothing to type), and the
-- phone's location shows the test was done at the space. A test done
-- at the space goes on the page when the owner presses "Put it on my
-- page"; any other test does not. Owners who cannot test there send a
-- Speedtest result link instead, which the team checks by hand (that
-- stays a chat message, as before).
--
-- The checks are made here, not in the app:
--   * mobile_data    the device said it is on mobile data
--   * no_location    no location (refused, or the device has none)
--   * rough_location the location is only known to within 300 m+
--   * no_pin         the space has no pin on the map to compare with
--   * too_far        more than 250 m from the pin
--   * at_space       none of the above: this one can go on the page
-- Also kept, for the team: an anonymous fingerprint of the network
-- (the same one nomads' tests use, so later tests can be compared) and
-- the country the connection comes from when the request carries it.
-- ============================================================

alter table public.venues
  add column if not exists wifi_owner_tested_at timestamptz;

comment on column public.venues.wifi_owner_tested_at is
  'When the owner''s on-site Wi-Fi test (migration 262) set wifi_speed_mbps. '
  'The nightly Webflow pull leaves wifi_speed_mbps alone once set.';

create table if not exists public.owner_wifi_tests (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues(id) on delete cascade,
  owner_email  text not null,
  created_at   timestamptz not null default now(),
  mbps         numeric not null,
  lat          double precision,
  lng          double precision,
  accuracy_m   double precision,
  distance_m   double precision,
  connection   text,
  network_hash text,
  ip_country   text,
  verdict      text not null,
  applied_at   timestamptz
);

create index if not exists owner_wifi_tests_venue
  on public.owner_wifi_tests (venue_id, created_at desc);

-- Only through the functions below (and the service role).
alter table public.owner_wifi_tests enable row level security;

create or replace function public.owner_wifi_test(
  p_venue uuid, p_mbps numeric,
  p_lat double precision, p_lng double precision,
  p_accuracy double precision, p_connection text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
  v       public.venues%rowtype;
  em      text := public.owner_email();
  dist    double precision;
  verdict text;
  hdr     json := nullif(current_setting('request.headers', true), '')::json;
  today   int;
  t_id    uuid;
begin
  v := public.billing_venue(p_venue, true);   -- the owner only
  if p_mbps is null or p_mbps <= 0 or p_mbps > 10000 then
    raise exception 'That test did not give a speed. Please try again.';
  end if;
  select count(*) into today from public.owner_wifi_tests
   where venue_id = v.id and created_at > now() - interval '1 day';
  if today >= 20 then
    raise exception 'That is a lot of tests today. Please try again tomorrow.';
  end if;

  if p_lat is not null and p_lng is not null and v.lat is not null and v.lng is not null then
    -- distance in metres (haversine)
    dist := 2 * 6371000 * asin(sqrt(
      power(sin(radians(p_lat - v.lat) / 2), 2)
      + cos(radians(v.lat)) * cos(radians(p_lat))
        * power(sin(radians(p_lng - v.lng) / 2), 2)));
  end if;

  verdict := case
    when p_connection = 'cellular'                 then 'mobile_data'
    when p_lat is null or p_lng is null            then 'no_location'
    when coalesce(p_accuracy, 0) > 300             then 'rough_location'
    when v.lat is null or v.lng is null            then 'no_pin'
    when dist > 250                                then 'too_far'
    else 'at_space' end;

  insert into public.owner_wifi_tests
    (venue_id, owner_email, mbps, lat, lng, accuracy_m, distance_m,
     connection, network_hash, ip_country, verdict)
  values
    (v.id, em, round(p_mbps, 1), p_lat, p_lng, p_accuracy, round(dist::numeric, 0),
     nullif(p_connection, ''), public.network_fingerprint(),
     upper(nullif(hdr ->> 'cf-ipcountry', '')), verdict)
  returning id into t_id;

  return jsonb_build_object(
    'id', t_id,
    'verdict', verdict,
    'mbps', round(p_mbps)::int,
    'distance_m', round(dist::numeric, 0),
    'space', v.name);
end $$;

create or replace function public.owner_wifi_test_apply(p_test uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  t   public.owner_wifi_tests%rowtype;
  v   public.venues%rowtype;
  mb  int;
begin
  select * into t from public.owner_wifi_tests where id = p_test for update;
  if not found then raise exception 'That test was not found.'; end if;
  v := public.billing_venue(t.venue_id, true);
  if t.verdict <> 'at_space' then
    raise exception 'Only a test done at the space can go on the page.';
  end if;
  if t.created_at < now() - interval '30 minutes' then
    raise exception 'That test is too old. Please run it again.';
  end if;
  mb := greatest(round(t.mbps)::int, 1);
  if t.applied_at is null then
    update public.owner_wifi_tests set applied_at = now() where id = t.id;
    update public.venues
       set wifi_speed_mbps = mb,
           wifi_owner_tested_at = now(),
           listing_sync_requested_at = now(),
           listing_synced_at = null,
           listing_sync_error = null
     where id = v.id;
    -- a line in Inbox & support, so the team sees it happened
    perform public.owner_chat_send(v.id,
      'Wi-Fi tested at the space: ' || mb || ' Mbps'
      || coalesce(' (' || round(t.distance_m)::int || ' m from the pin)', '')
      || '. It is going on the page.');
  end if;
  return jsonb_build_object('mbps', mb, 'space', v.name);
end $$;

revoke all on function public.owner_wifi_test(uuid, numeric, double precision, double precision, double precision, text) from public, anon;
revoke all on function public.owner_wifi_test_apply(uuid) from public, anon;
grant execute on function public.owner_wifi_test(uuid, numeric, double precision, double precision, double precision, text) to authenticated;
grant execute on function public.owner_wifi_test_apply(uuid) to authenticated;

-- The monthly email's tip and checklist: test, not "tell us".
do $$
declare d text;
begin
  select pg_get_functiondef('public.owner_monthly_model(uuid,date)'::regprocedure) into d;
  d := replace(d, $q$then 'Tell us' else 'Add' end$q$, $q$then 'Test' else 'Add' end$q$);
  d := replace(d, $q$when 'wifi' then 'Tell us your Wi-Fi speed'$q$, $q$when 'wifi' then 'Test your Wi-Fi speed'$q$);
  d := replace(d, $q$when 'wifi' then 'It is the first thing remote workers ask.'$q$,
                  $q$when 'wifi' then 'It is the first thing remote workers ask. Run the test at your space and it goes straight on your page.'$q$);
  d := replace(d, $q$when 'wifi' then 'Send your speed'$q$, $q$when 'wifi' then 'Run the test'$q$);
  execute d;
end $$;
