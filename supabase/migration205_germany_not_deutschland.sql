-- ============================================================
-- Migration 205: "Deutschland" is Germany.
--
-- Jonathan, 22 Oct 2026, on Pricing: "Deutschland" was listed under
-- Country names not recognised (one space, Cafe AMANO in Berlin, added
-- through the claim form). Google gave the country in the language of
-- the owner's browser. The space's country is now Germany everywhere
-- we keep it, so it is priced and placed as Germany. (The app now asks
-- Google for English names, so this does not happen again.)
--
-- Its page address changed the same day, with Jonathan's Go, from
-- coworking/deutschland-berlin-cafe-amano to
-- coworking/germany-berlin-cafe-amano (renamed and published in
-- Webflow from a session); the space's record follows.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

update public.venues set country = 'Germany' where btrim(country) = 'Deutschland';
update public.listing_claims set space_country = 'Germany' where btrim(space_country) = 'Deutschland';
update public.space_contacts set country = 'Germany' where btrim(country) = 'Deutschland';

update public.venues
   set webflow_slug = 'germany-berlin-cafe-amano'
 where webflow_slug = 'deutschland-berlin-cafe-amano';
