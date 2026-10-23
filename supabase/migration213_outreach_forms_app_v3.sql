-- ============================================================
-- Migration 213: Leonie's email to the forms.app sign-ups, as an
-- Outreach template.
-- (Applied automatically by the build; nothing to paste.)
--
-- CR-19. Leonie wrote "Version 3: we've been working on something
-- new" (23 Oct) for the coworking spaces that signed up through our
-- old forms.app forms and whose pages are live now. As a template,
-- the space's name, the person's first name and the space's own claim
-- link fill in by themselves, and every send is logged on the card.
-- Nothing is sent by this: a founder picks the template and presses
-- Send in Outreach.
--
-- Two small changes to Leonie's words, to follow the rules for owner
-- emails (flagged to her on CR-19): "members area" reads "Owner
-- account", and "In the next few weeks, we'll be rolling out" reads
-- "We'll also be adding" (no time promises). The sign-off is the
-- usual {signoff} (Kind regards, Jonathan Heavens, Cofounder -
-- Nomadwise.io). The two emoji are Leonie's, written here with chr()
-- so this file stays pure ASCII.
-- Safe to apply twice: an existing template with this key is left as
-- it is (it may have been edited in Outreach).
-- ============================================================

insert into public.outreach_templates (key, name, subject, body, stream, sort)
values (
  'forms_app_v3',
  'forms.app sign-ups: we have been working on something new',
  '{space} now live on Nomadwise',
  'Hi {first_name},' || E'\n\n'
  || 'Sorry it''s been quiet from our side! We''ve been focused on restructuring '
  || 'how we list coworking spaces on Nomadwise.' || E'\n\n'
  || 'Good news though: we''ve built a new Owner account where you can manage '
  || 'your own profile. You can claim your business right here: {claim_link}'
  || E'\n\n'
  || chr(128140) || ' We''re still actively building this out, so if anything feels '
  || 'clunky or you''ve got ideas on how to make it more useful for you as a '
  || 'coworking space manager, reply to this email or drop us your feedback at '
  || 'hello@nomadwise.io. We''d genuinely love to hear it.' || E'\n\n'
  || chr(128161) || ' Claiming a profile is free. We''ll also be adding the option '
  || 'to upgrade your profile to Nomadwise Plus, to help you stand out even more.'
  || E'\n\n'
  || 'More on that soon!' || E'\n\n'
  || '{signoff}',
  'outbound',
  70)
on conflict (key) do nothing;

notify pgrst, 'reload schema';
