-- Migration 360: what a customer is sent about their request is
-- blind-copied to spaces@nomadwise.io (Jonathan, 24 Nov 2026: "yes i
-- think request confirmations to customers should be copied to
-- spaces@").
--
-- Before: the email to a space about a request was copied to spaces@
-- (Cc), so the team saw it. The emails to the customer were not:
-- "we have your request" (enquiry_received_nomad), "we passed it on"
-- (enquiry_passed_nomad) and "we could not reach the space"
-- (enquiry_unreachable_nomad) went to the customer alone.
--
-- Now every email of a kind ending _nomad carries Bcc spaces@. Blind,
-- so the customer sees one sender and no second address, and a reply
-- from the customer goes where it went before. Emails to a space are
-- not changed. Nothing is copied when the email is already going to
-- spaces@ itself.
--
-- Applied to the live database on 24 Nov 2026 (16:44 UTC). Tried in a
-- rolled-back test: enquiry_passed_nomad carried Bcc spaces@;
-- enquiry_passed (to a space) was unchanged, with its Cc as before.

select public.pm_patch_fn('public.send_enquiry_mail(text,text,text,text,text,text,uuid,text)',
  $a$  if coalesce(p_cc, '') <> '' and lower(p_cc) <> lower(p_to) then
    payload := payload || jsonb_build_object('Cc', p_cc);
  end if;$a$,
  $a$  if coalesce(p_cc, '') <> '' and lower(p_cc) <> lower(p_to) then
    payload := payload || jsonb_build_object('Cc', p_cc);
  end if;
  -- What the customer is sent about their request (kinds ending
  -- _nomad) is blind-copied to us, so the team sees it in the spaces@
  -- inbox (migration 360). Blind, so the customer sees one sender only.
  if coalesce(p_kind, '') like '%\_nomad' and lower(coalesce(p_to, '')) <> 'spaces@nomadwise.io' then
    payload := payload || jsonb_build_object('Bcc', 'spaces@nomadwise.io');
  end if;$a$,
  $a$blind-copied to us, so the team sees it$a$);
