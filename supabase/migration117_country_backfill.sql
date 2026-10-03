-- ============================================================
-- Migration 117: every space gets its country.
-- (Applied automatically by the build; nothing to paste.)
--
-- Verified is priced by the space's country (migration 115), but most
-- spaces never had one recorded: the Pricing page counted 32 spaces in
-- four groups out of hundreds. Two fixes:
--   * here: a space whose city is one of the site's Regions takes that
--     Region's country (the Regions list carries it);
--   * nightly (enrich_venues.py): the rest get theirs from Google's
--     address parts, a few hundred a night, inside the free tier.
-- A country already on a space is never overwritten.
-- ============================================================

update public.venues v
   set country = r.country
  from public.webflow_regions r
 where coalesce(trim(v.country), '') = ''
   and coalesce(trim(r.country), '') <> ''
   and lower(trim(v.city)) = lower(trim(r.name));

-- The claim form's search returns the space's country for the price;
-- a space still without one is priced as group B until the night job
-- fills it in.
