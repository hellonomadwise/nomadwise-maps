-- ============================================================
-- Migration 237: coworking mail goes from spaces@nomadwise.io.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 3 Nov 2026 (CR-34): spaces@nomadwise.io is the shared
-- inbox for the coworking side, read by Jonathan and Leonie in Spark.
-- Everything a space, an owner or a nomad with an enquiry receives
-- comes from it; hello@ is kept for everything else (the website chat,
-- partners, general mail).
--   From        "Nomadwise Spaces <spaces@nomadwise.io>"
--               (was "Jonathan at Nomadwise <hello@...>" or
--               "Nomadwise <hello@...>")
--   Reply-To, Bcc and Cc copies, the default for enquiries to a space
--   with no address of its own, our own notices (a Premium renewal
--   cancelled) and the words in error messages: spaces@.
-- Functions: send_owner_email, send_owner_email_reply_to,
-- admin_outreach_send, send_enquiry, send_enquiry_mail,
-- enquiry_send_to_space, admin_enquiry_pass_on, admin_enquiry_close,
-- admin_enquiries_tell_nomad, owner_billing_action, start_claim,
-- admin_sequences. Each is patched where it stands (only the address
-- and the sender name change). Left on hello@: site_chat_send (the
-- nomadwise.io chat, not coworking).
-- The forms.app outreach template's "drop us your feedback at hello@"
-- now says spaces@.
-- Replies: chat_inbound already treats any @nomadwise.io sender as
-- ours, so the hidden copies to spaces@ are not taken for owners'.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

do $do$
declare
  r   record;
  src text;
  n   integer := 0;
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public'
       and p.proname in ('send_owner_email', 'send_owner_email_reply_to',
                         'admin_outreach_send', 'send_enquiry', 'send_enquiry_mail',
                         'enquiry_send_to_space', 'admin_enquiry_pass_on',
                         'admin_enquiry_close', 'admin_enquiries_tell_nomad',
                         'owner_billing_action', 'start_claim', 'admin_sequences')
       and p.prosrc like '%hello@nomadwise.io%'
  loop
    src := pg_get_functiondef(r.oid);
    src := replace(src, 'Jonathan at Nomadwise <hello@nomadwise.io>',
                        'Nomadwise Spaces <spaces@nomadwise.io>');
    src := replace(src, 'Nomadwise <hello@nomadwise.io>',
                        'Nomadwise Spaces <spaces@nomadwise.io>');
    src := replace(src, 'hello@nomadwise.io', 'spaces@nomadwise.io');
    execute src;
    n := n + 1;
  end loop;
  raise notice 'migration 237: % functions now use spaces@', n;
end
$do$;

update public.outreach_templates
   set body = replace(body, 'hello@nomadwise.io', 'spaces@nomadwise.io')
 where body like '%hello@nomadwise.io%';
