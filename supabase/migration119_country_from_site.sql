-- ============================================================
-- Migration 119: a country for every space, from what we already know.
-- (Applied automatically by the build; nothing to paste.)
--
-- Verified is priced by the space's country. Migration 117 filled it
-- only where the city is one of the site's Regions, so a space in
-- Kedungu or Canggu (Locations inside the Bali Region) still had none
-- and was priced as group B, "€10 a month", instead of Indonesia's.
--
-- venue_country_guess() works the country out from, in order:
--   1. the page proposal the sync prepared (it names the country);
--   2. the Location or Region a founder picked for the page;
--   3. the city or neighbourhood being a Location or Region on the site;
--   4. Google's cached address parts;
--   5. the nearest Region on the map within 30 km (the sync's own
--      rule), once the sync has copied the Regions' coordinates.
-- A country already on a space is never changed.
--
-- It runs three ways: once now for every space without a country; from
-- a trigger whenever a space without one is added or touched; and from
-- fill_venue_countries(), which the Webflow sync calls after copying
-- the Regions, so the map step reaches spaces nothing else touches.
-- admin_pricing() now also counts the spaces still without a country,
-- for the Pricing page.
-- ============================================================

alter table public.webflow_regions
  add column if not exists lat double precision,
  add column if not exists lng double precision;

create or replace function public.venue_country_guess(v public.venues)
returns text language plpgsql stable set search_path = public as $$
declare
  c text;
  n text;
begin
  c := nullif(trim(coalesce(v.country, '')), '');
  if c is not null then return c; end if;

  -- 1. The page proposal.
  if jsonb_typeof(v.website_prepared) = 'object' then
    c := nullif(trim(coalesce(v.website_prepared ->> 'country', '')), '');
    if c is not null then return c; end if;
  end if;

  -- 2. A Location or Region a founder picked.
  if coalesce(v.website_location_override, '') not in ('', 'none') then
    select coalesce(nullif(trim(l.country), ''), nullif(trim(r.country), '')) into c
      from public.webflow_locations l
      left join public.webflow_regions r on r.id = l.region_id
     where l.id = v.website_location_override;
    if c is not null then return c; end if;
  end if;
  if coalesce(v.website_region_override, '') <> '' then
    select nullif(trim(r.country), '') into c
      from public.webflow_regions r
     where (r.id = v.website_region_override
            or lower(trim(r.name)) = lower(trim(v.website_region_override)))
       and coalesce(trim(r.country), '') <> ''
     limit 1;
    if c is not null then return c; end if;
  end if;

  -- 3. The city or neighbourhood is a Location or a Region on the site.
  foreach n in array array[v.neighbourhood, v.city] loop
    n := lower(trim(coalesce(n, '')));
    if n = '' then continue; end if;
    select coalesce(nullif(trim(l.country), ''), nullif(trim(r.country), '')) into c
      from public.webflow_locations l
      left join public.webflow_regions r on r.id = l.region_id
     where lower(trim(l.name)) = n
       and coalesce(nullif(trim(l.country), ''), nullif(trim(r.country), '')) is not null
     limit 1;
    if c is not null then return c; end if;
    select nullif(trim(r.country), '') into c
      from public.webflow_regions r
     where lower(trim(r.name)) = n and coalesce(trim(r.country), '') <> ''
     limit 1;
    if c is not null then return c; end if;
  end loop;

  -- 4. Google's address parts, when the details are cached.
  if jsonb_typeof(v.g_details -> 'addressComponents') = 'array' then
    select nullif(trim(coalesce(x ->> 'longText', x ->> 'shortText', '')), '') into c
      from jsonb_array_elements(v.g_details -> 'addressComponents') x
     where jsonb_typeof(x -> 'types') = 'array' and x -> 'types' ? 'country'
     limit 1;
    if c is not null then return c; end if;
  end if;

  -- 5. The nearest Region on the map, within 30 km.
  if v.lat is not null and v.lng is not null then
    select nullif(trim(r.country), '') into c
      from public.webflow_regions r
     where r.lat is not null and r.lng is not null
       and coalesce(trim(r.country), '') <> ''
       and 6371 * 2 * asin(sqrt(least(1,
             power(sin(radians(r.lat - v.lat) / 2), 2)
             + cos(radians(v.lat)) * cos(radians(r.lat))
             * power(sin(radians(r.lng - v.lng) / 2), 2)))) <= 30
     order by power(r.lat - v.lat, 2)
            + power((r.lng - v.lng) * cos(radians(v.lat)), 2)
     limit 1;
    if c is not null then return c; end if;
  end if;

  return null;
end $$;
-- Read-only, and the trigger below runs it as whoever writes the row.
grant execute on function public.venue_country_guess(public.venues) to anon, authenticated, service_role;

-- A space added or touched without a country gets one on the way in.
create or replace function public.venue_country_fill()
returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(trim(new.country), '') = '' then
    new.country := public.venue_country_guess(new);
  end if;
  return new;
end $$;
drop trigger if exists venue_country_fill on public.venues;
create trigger venue_country_fill
  before insert or update on public.venues
  for each row execute function public.venue_country_fill();

-- Every space still without a country, in one go. Returns how many
-- were filled. The sync calls it after copying the Regions.
create or replace function public.fill_venue_countries()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.venues v
     set country = public.venue_country_guess(v)
   where coalesce(trim(v.country), '') = ''
     and public.venue_country_guess(v) is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.fill_venue_countries() from public, anon, authenticated;
grant execute on function public.fill_venue_countries() to service_role;

select public.fill_venue_countries();

-- The Pricing page: how many spaces still have no country at all.
create or replace function public.admin_pricing()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  -- Each distinct country text is matched once, not once per venue.
  drop table if exists pricing_venue_iso;
  create temp table pricing_venue_iso on commit drop as
    select x.country, public.pricing_country_iso(x.country) as iso,
           x.n, x.verified
      from (select v.country, count(*) n,
                   count(*) filter (where v.listing_tier = 'verified') verified
              from public.venues v
             where coalesce(v.website_status, '') <> 'retired'
             group by v.country) x;
  return jsonb_build_object(
    'groups', (select jsonb_agg(to_jsonb(g) || jsonb_build_object(
                 'spaces', coalesce((select sum(x.n) from pricing_venue_iso x
                                       join public.pricing_countries c on c.iso = x.iso
                                      where c.group_code = g.code), 0),
                 'verified', coalesce((select sum(x.verified) from pricing_venue_iso x
                                         join public.pricing_countries c on c.iso = x.iso
                                        where c.group_code = g.code), 0))
               order by g.sort) from public.pricing_groups g),
    'countries', (select jsonb_agg(jsonb_build_object(
                    'iso', c.iso, 'name', c.name, 'group', c.group_code,
                    'currency', c.currency, 'locked', c.currency_locked,
                    'spaces', coalesce((select sum(x.n) from pricing_venue_iso x where x.iso = c.iso), 0))
                  order by c.name) from public.pricing_countries c),
    'unmapped', coalesce((select jsonb_agg(jsonb_build_object('country', x.country, 'spaces', x.n) order by x.n desc)
                  from pricing_venue_iso x
                 where x.iso is null and coalesce(trim(x.country), '') <> ''), '[]'::jsonb),
    'no_country', coalesce((select sum(x.n) from pricing_venue_iso x
                             where coalesce(trim(x.country), '') = ''), 0),
    'stripe_connected', exists (select 1 from vault.decrypted_secrets
                                 where name = 'stripe_billing_key' and coalesce(decrypted_secret, '') <> ''));
end $$;
revoke all on function public.admin_pricing() from public, anon;
grant execute on function public.admin_pricing() to authenticated;
