-- 182: the price sentence says it once again.
--
-- Jonathan, 10 Oct 2026, on the hello to Level39 ("... for 13 pounds a month
-- or 129 pounds a year, monthly or yearly, cancel any time"): "from this
-- outreach template can you remove the "monthly or yearly"".
-- Migration 122 fixed this in the first templates; the two written
-- since (reply_we_know_you, 171, and invite_new_page, 178 and 179)
-- brought the words back. Same change as 122, for every template: the
-- price words already say a month or a year, so the sentence now ends
-- "for {price_words}. Cancel any time." A template reworded by hand
-- without these exact words is left alone.
-- Pure ASCII. Safe to apply twice.

update public.outreach_templates
   set body = replace(replace(body,
                ', for {price_words}, monthly or yearly, cancel any time.',
                ', for {price_words}. Cancel any time.'),
                ', that is {price_words}, monthly or yearly, cancel any time.',
                ', that is {price_words}. Cancel any time.'),
       updated_at = now()
 where body like '%{price_words}, monthly or yearly, cancel any time.%';
