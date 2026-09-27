-- ============================================================
-- Migration 80: one-off data fix for the first free claim.
-- (Applied automatically by the build; nothing to paste.)
--
-- The claim form guessed the country from the end of Google's short
-- address, which for Sri Lankan places is the town, so Kopi Club
-- arrived as "Kandy, Kandy". The app now reads the country from
-- Google's address components; this repairs the rows already saved.
-- ============================================================

update public.listing_claims
   set space_country = 'Sri Lanka'
 where space_country = 'Kandy';

update public.venues
   set country = 'Sri Lanka'
 where country = 'Kandy';
