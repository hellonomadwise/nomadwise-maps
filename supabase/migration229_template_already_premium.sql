-- ============================================================
-- Migration 229: an Outreach template for a space we already put on
-- Premium ourselves.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 29 Oct 2026: some spaces we set up on Premium as a thank
-- you and a trial (Ofis Voyvoda in Istanbul, Sep 2024). "Owner
-- account: a space we know" offered them Premium again. This template
-- is the same email, but tells them they already have it. Outreach
-- picks it by itself for a space set up by us on Premium; it can be
-- changed in the Write box before sending, as always.
-- Pure ASCII. Safe to apply twice (an existing row is left alone).
-- ============================================================

insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('reply_we_know_you_premium',
 'Owner account: a space we know, already on Premium',
 'Your page on Nomadwise: {space}',
 E'Hi {first_name},\n\n'
 'We have been in touch before about {space}, and I wanted to tell you about something new.\n\n'
 '{space} is on nomadwise.io: {page_link}\n\n'
 'It is already on Nomadwise Premium, which we set up for you as a thank you, so your page has '
 'the Verified by Nomadwise badge and top positioning on your region''s page.\n\n'
 'You can now take the page over yourself, free, from your own Owner account. Claim it here: {claim_link}\n\n'
 'From there you can update your opening hours and contact details, and add your own photos, '
 'description and prices. Every change is read by a person before it goes live.\n\n'
 '{signoff}',
 'outbound', 26)
on conflict (key) do nothing;
