-- ============================================================
-- Nomadwise Maps — migration 38: "serves food" (real lunch, not
-- just coffee and pastries)
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

-- Community-confirmed answer on venues (null = not asked yet).
alter table public.venues
  add column if not exists serves_food boolean;

-- Review-scan signal on unscreened places: how many Google reviews
-- mention real food (lunch, brunch, salads...). Filled by the same
-- monthly scan that finds "promising" places.
alter table public.discovered_places
  add column if not exists signal_food integer not null default 0;

-- Verified confirmations now also merge the food answer.
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
      good_for_calls      = coalesce((new.payload->>'good_for_calls')::boolean, v.good_for_calls),
      call_room           = coalesce((new.payload->>'call_room')::boolean, v.call_room),
      monitor             = coalesce((new.payload->>'monitor')::boolean, v.monitor),
      office_chairs       = coalesce((new.payload->>'office_chairs')::boolean, v.office_chairs),
      access_24h          = coalesce((new.payload->>'access_24h')::boolean, v.access_24h),
      serves_food         = coalesce((new.payload->>'serves_food')::boolean, v.serves_food),
      neighbourhood       = coalesce(nullif(new.payload->>'neighbourhood',''), v.neighbourhood),
      last_confirmed_at   = now(),
      updated_at          = now()
    where v.id = new.venue_id;
  end if;
  return new;
end $$;
