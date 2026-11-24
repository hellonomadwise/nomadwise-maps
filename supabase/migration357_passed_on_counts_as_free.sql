-- Migration 357: a request passed on by hand counts as a free request.
--
-- Jonathan, 24 Nov 2026, after Giulia's request for TLoft Coworking
-- Space (Bangkok, unclaimed) was passed on to info@tloftbkk.com: "this
-- should count as 1 free request", then "Yes, from now on".
--
-- Before: only a request that went out by itself to a claimed space
-- (route 'free') was counted (enquiries.free_slot). One a founder passed
-- on to an unclaimed space, by email or WhatsApp, was never counted, so
-- a space could receive any number before claiming and still start at
-- 0 of 2.
--
-- Now: passing a request on counts it, while the space is under the
-- limit and not on Premium. Above the limit a founder can still pass
-- one on; it is then not counted, so the count never reads "3 of 2".
-- Requests passed on before today are left as they were (his choice).
-- TLoft's was counted by hand on 24 Nov.

create or replace function public.enquiry_pass_counts_free(p_venue uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select coalesce((public.free_enquiry_rule() ->> 'on')::boolean, false)
     and coalesce((select v.listing_tier from public.venues v where v.id = p_venue), 'free') <> 'verified'
     and public.free_enquiries_used(p_venue) < (public.free_enquiry_rule() ->> 'limit')::int;
$$;
revoke all on function public.enquiry_pass_counts_free(uuid) from public, anon, authenticated;

select public.pm_patch_fn(
  'public.admin_enquiry_pass_on(uuid,text,boolean,text,text)',
  'to_email = dest, sent_at = now(), send_error = null',
  'to_email = dest, sent_at = now(), send_error = null,
         free_slot = coalesce(free_slot, false) or public.enquiry_pass_counts_free(e.venue_id)',
  'enquiry_pass_counts_free');

select public.pm_patch_fn(
  'public.admin_enquiry_passed_whatsapp(uuid,text,text,boolean,text,text)',
  'left(''WhatsApp '' || ph, 200), passed_at = now(),',
  'left(''WhatsApp '' || ph, 200), passed_at = now(),
         free_slot = coalesce(free_slot, false) or public.enquiry_pass_counts_free(e.venue_id),',
  'enquiry_pass_counts_free');
