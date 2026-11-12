-- ============================================================
-- Migration 324: outreach letters stop saying "around a day pass a month"
-- ============================================================
-- Jonathan, 12 Nov 2026: "i dont know if i like the reference of a day
-- pass, because this varies quite a lot. so if we make it just clear
-- on what the pricing is, and that they can cancel at anytime", then
-- "can you change where the other references mention around a day pass
-- a month".
--
-- The letters name the Premium price for the space's country
-- ({price_words}: "€6 a month or €60 a year"). When the country is not
-- known there is no figure to give (never another country's), and the
-- words in its place were the day-pass comparison. Now: "a monthly or
-- yearly fee, shown on the claim form before you pay". In the one
-- template that uses it the sentence reads "... unlimited enquiries
-- straight to your inbox, for a monthly or yearly fee, shown on the
-- claim form before you pay. Cancel any time."
-- ============================================================

select public.pm_patch_fn('public.admin_outreach_preview(uuid, text)',
$a$                else 'around a day pass a month' end;$a$,
$a$                else 'a monthly or yearly fee, shown on the claim form before you pay' end;$a$,
$m$shown on the claim form before you pay$m$);
