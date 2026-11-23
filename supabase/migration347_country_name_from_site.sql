-- ============================================================
-- Migration 347: one name per country, the website's.
-- (Applied automatically by the build; nothing to paste.)
--
-- A space made from Google or a claim carries Google's country word,
-- so the same country showed under two names: Czechia and Czech
-- Republic, Cabo Verde and Cape Verde, United Kingdom and England.
-- Counts by country (the Coworking Global page, admin screens) split
-- them in two. Jonathan (23 Nov 2026): use the name most users of the
-- site understand. That is the website's own Country name, which the
-- Webflow sync already prefers for page addresses (country_of in
-- scripts/webflow_sync.py).
--
-- Rule: when a space's Region on the site has a Country, and the
-- space's word is the same country under another name (same ISO code,
-- pricing_country_iso), the space takes the site's name. A word that
-- is a DIFFERENT country from its Region (a data conflict, such as a
-- Bratislava cafe marked Czech Republic) is left alone and listed by
-- country_name_conflicts() for a person to look at.
--
-- Runs once now for every space, and from a trigger whenever a
-- space's country or Region is set or changed.
-- ============================================================

create or replace function public.venue_site_country(v public.venues)
returns text language plpgsql stable set search_path = public as $$
declare
  site text;
begin
  if v.webflow_region_id is null then return v.country; end if;
  select nullif(trim(r.country), '') into site
    from public.webflow_regions r where r.id = v.webflow_region_id;
  if site is null or v.country is null or v.country = site then
    return v.country;
  end if;
  if public.pricing_country_iso(v.country) is not null
     and public.pricing_country_iso(v.country) = public.pricing_country_iso(site) then
    return site;
  end if;
  return v.country;
end $$;

create or replace function public.venues_site_country_name()
returns trigger language plpgsql set search_path = public as $$
begin
  new.country := public.venue_site_country(new);
  return new;
end $$;

drop trigger if exists venues_site_country_name on public.venues;
create trigger venues_site_country_name
  before insert or update of country, webflow_region_id on public.venues
  for each row execute function public.venues_site_country_name();

-- Once now.
update public.venues v
   set country = public.venue_site_country(v)
 where v.country is distinct from public.venue_site_country(v);

-- Spaces whose country word names a different country from their
-- Region: for a person to check (wrong Region, or wrong country).
create or replace function public.country_name_conflicts()
returns table (venue_id uuid, name text, country text, region text, region_country text, webflow_slug text)
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.country, r.name, r.country, v.webflow_slug
    from public.venues v
    join public.webflow_regions r on r.id = v.webflow_region_id
   where public.is_admin()
     and coalesce(trim(r.country), '') <> ''
     and v.country is not null
     and v.country <> r.country
     and coalesce(public.pricing_country_iso(v.country), v.country)
         <> coalesce(public.pricing_country_iso(r.country), r.country)
   order by r.country, v.name
$$;
revoke all on function public.country_name_conflicts() from public, anon;
grant execute on function public.country_name_conflicts() to authenticated, service_role;
