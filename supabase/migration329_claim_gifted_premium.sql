-- Migration 329: a space we put on Premium ourselves can claim its page.
--
-- 16 Nov 2026. Aytek at Ofis Voyvoda Istanbul, forty minutes after our
-- email ("we have put it on Nomadwise Premium ... you can now look
-- after and update your page yourself, for free"): "Unfortunately, the
-- link you have sent does not work."
--
-- Two places took "on Premium" to mean "somebody has claimed it":
--   claim_search  marked the space "already on Premium", so the claim
--                 link did not pick it, and tapping it in the list
--                 said "Someone has already claimed this listing";
--   start_claim   refused the claim with "This listing is already on
--                 Premium".
-- True for a space that paid, not for the six we put on Premium as a
-- thank you and that nobody has claimed (Ofis Voyvoda, SOKKOOL, DEOS,
-- Neighbors and Nomads, Nomio, Monday). Both now ask for an owner as
-- well. A free claim leaves the Premium in place (claim_approve_do
-- does not touch the tier).

select public.pm_patch_fn('public.claim_search(text)',
  $a$v.listing_tier = 'verified',$a$,
  $a$(v.listing_tier = 'verified' and coalesce(btrim(v.listing_owner_email), '') <> ''),$a$,
  $a$v.listing_tier = 'verified' and coalesce(btrim(v.listing_owner_email)$a$);

select public.pm_patch_fn('public.start_claim(jsonb)',
  $a$if v.listing_tier = 'verified' then$a$,
  $a$if v.listing_tier = 'verified' and coalesce(btrim(v.listing_owner_email), '') <> '' then$a$,
  $a$v.listing_tier = 'verified' and coalesce(btrim(v.listing_owner_email)$a$);
