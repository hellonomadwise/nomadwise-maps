-- Migration 165: Outreach templates say what an owner can change, not
-- "the facts".
--
-- Jonathan, 8 Oct 2026, replying to Workland Fahle with "Follow-up:
-- someone looked at the claim page": "can we change this template to
-- not say "facts"". The same words stand in three more templates
-- (the first invitation, "they made an account on the map", and
-- "Claimed: how to get into their Owner account"), so all four change
-- together. Only those words change: anything else Jonathan has
-- edited in a template in Outreach, Templates stays as it is, and a
-- template that no longer has the words is left alone.
--
--   "correct the facts and add your own photos, description and prices"
--     -> "update your opening hours and contact details, and add your
--         own photos, description and prices"
--   "correct the description, opening hours and facts, and add your
--    own photos and prices"
--     -> "update the description, opening hours and contact details,
--         and add your own photos and prices"

update public.outreach_templates
   set body = replace(body,
         'correct the facts and add your own photos, description and prices',
         'update your opening hours and contact details, and add your own photos, description and prices')
 where position('correct the facts and add your own photos, description and prices' in body) > 0;

update public.outreach_templates
   set body = replace(body,
         'correct the description, opening hours and facts, and add your own photos and prices',
         'update the description, opening hours and contact details, and add your own photos and prices')
 where position('correct the description, opening hours and facts, and add your own photos and prices' in body) > 0;
