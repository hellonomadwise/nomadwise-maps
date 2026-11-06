-- ============================================================
-- Migration 276: owner tips, small fixes before the test emails.
-- (Applied automatically by the build; nothing to paste.)
--
--  * "Since you last looked" only when there is something worth
--    showing: Google 20 or more, 5 or more page views, or anyone who
--    asked for directions or sent a request (1 page view is not news).
--  * "First request" says "recently" if the date is unknown.
--  * The subjects can carry a test label ({{subject_prefix}}, empty
--    for real sends), like the enquiry emails.
-- ============================================================

update public.email_templates set subject = '{{subject_prefix}}' || subject
 where alias like 'tip-%' and subject not like '{{subject_prefix}}%';

select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$'worth_sending', jsonb_array_length(coalesce(rows, '[]'::jsonb)) > 0,$a$,
  $a$'worth_sending', (g >= 20 or views >= 5 or dirs > 0 or reqs > 0),$a$,
  $m$views >= 5$m$);

select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$                   else 'on ' || trim(to_char(fr, 'FMDD FMMonth')) end,$a$,
  $a$                   when fr is null then 'recently'
                   else 'on ' || trim(to_char(fr, 'FMDD FMMonth')) end,$a$,
  $m$then 'recently'$m$);

-- A business name in the name box ("Hotel AMANO") is not a first name:
-- then "Hi there".
select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$  parts := public.page_parts(v.id);
  nx := public.owner_tip_part(parts ->> 'next');$a$,
  $a$  if lower(first) in ('hotel', 'team', 'the', 'info', 'sales', 'admin', 'hello', 'cafe', U&'caf\00E9', 'coworking',
                      'cowork', 'manager', 'management', 'reception', 'contact', 'office', 'space', 'studio', 'hub')
     or position(' ' || lower(first) || ' ' in ' ' || lower(coalesce(v.name, '')) || ' ') > 0 then
    first := 'there';
  end if;
  parts := public.page_parts(v.id);
  nx := public.owner_tip_part(parts ->> 'next');$a$,
  $m$'reception', 'contact'$m$);
