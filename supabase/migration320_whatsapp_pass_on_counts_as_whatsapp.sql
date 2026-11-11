-- ============================================================
-- Migration 320: an enquiry passed on by WhatsApp counts as WhatsApp
-- ============================================================
-- Migration 316 kept the message in Outreach under the subject
-- "WhatsApp: an enquiry passed on". Home's "Outreach sent each week"
-- (admin_home) tells the ways apart by that word alone: 'WhatsApp',
-- 'Instagram', 'Facebook', 'Contact form', anything else is email. So
-- the first one (Coworking Space H24, 11 Nov 2026) would have shown as
-- an email. The subject is now the plain word, as the Outreach
-- WhatsApp button writes it; template_key enquiry_passed_wa still says
-- what kind of message it was. H24's was put right by hand on the day.
-- ============================================================

select public.pm_patch_fn(
  'public.admin_enquiry_passed_whatsapp(uuid, text, text, boolean, text, text)',
$a$values (cid, 'out', 'enquiry_passed_wa', 'WhatsApp: an enquiry passed on',$a$,
$a$values (cid, 'out', 'enquiry_passed_wa', 'WhatsApp',   -- the plain word: Home counts by it (migration 320)$a$,
$m$Home counts by it (migration 320)$m$);

update public.outreach_messages
   set subject = 'WhatsApp'
 where template_key = 'enquiry_passed_wa'
   and subject = 'WhatsApp: an enquiry passed on';
