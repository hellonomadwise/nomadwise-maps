-- ============================================================
-- Migration 294: {city} in outreach reads like a place, and the
-- WhatsApp to a space that started claiming
-- ============================================================
-- Jonathan, 9 Nov 2026, on the WhatsApp to Zest Ubud. He rewrote it:
--   "Hi Zest team, this is Jonathan from Nomadwise. Zest Ubud has a
--   page on nomadwise.io, where remote workers look for good places to
--   work in Ubud. ..."
-- Written from the template, "in {city}" came out "in Kabupaten
-- Gianyar" (Google's district name for much of Bali), and the first-
-- contact email (invite_listed) had the same problem. {city} is now
-- the place as our pages name it: the area and its city page ("Ubud,
-- Bali", "Canary Wharf, London"), else the city page ("Arusha"), else
-- the city as before.
-- ============================================================

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  city  := coalesce(nullif(trim(c.city), ''), v.city, 'your city');$a$,
$a$  -- the place as our pages name it (migration 294)
  city  := coalesce(
             (select case when l.name is not null and r.name is not null and l.name <> r.name
                          then l.name || ', ' || r.name
                          else coalesce(r.name, l.name) end
                from (select 1) one
                left join public.webflow_regions r on r.id = v.webflow_region_id
                left join public.webflow_locations l on l.id = v.webflow_location_id),
             nullif(trim(c.city), ''), v.city, 'your city');$a$,
$m$the place as our pages name it$m$);

update public.outreach_templates
   set body = E'Hi {space} team, this is Jonathan from Nomadwise. {space} has a page on nomadwise.io, where remote workers look for good places to work in {city}. It looks like someone from your side started claiming it recently, so I wanted to check in. Is there anything I can help with?\n\n'
           || E'Claiming is free and takes about a minute. Once it''s yours, you can add your own photos, opening hours and prices whenever you like.\n\n'
           || '{claim_link}',
       updated_at = now()
 where key = 'claim_looked_wa';
