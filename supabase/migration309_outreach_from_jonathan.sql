-- ============================================================
-- Migration 309: outreach emails come from Jonathan
-- ============================================================
-- Jonathan, 10 Nov 2026: "if its a semi outreach email, I'm kind of
-- wanting it to come from jonathan@nomadwise.io bcc spaces@nomadwise.io".
-- "Send from here" in Outreach (admin_outreach_send) sent as Nomadwise
-- Spaces <spaces@nomadwise.io> with answers back to spaces@. It now
-- sends as Jonathan Heavens <jonathan@nomadwise.io>, a copy still to
-- spaces@nomadwise.io, and no reply address of its own, so an answer
-- goes to Jonathan. Postmark accepts the address (checked with a send
-- to its test address the same day). The owner emails in Postmark and
-- the enquiry emails are not touched.
-- ============================================================

select public.pm_patch_fn('public.admin_outreach_send(uuid,text,text,text,boolean)',
$a$      'From', 'Nomadwise Spaces <spaces@nomadwise.io>',
      'To', c.email,
      'ReplyTo', 'spaces@nomadwise.io',
      'Bcc', 'spaces@nomadwise.io',$a$,
$a$      -- from Jonathan himself, answers back to him, a copy to the shared
      -- inbox (migration 309)
      'From', 'Jonathan Heavens <jonathan@nomadwise.io>',
      'To', c.email,
      'Bcc', 'spaces@nomadwise.io',$a$,
$m$from Jonathan himself, answers back to him$m$);
