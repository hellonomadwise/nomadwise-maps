-- Migration 331: a space that knows us gets an email without the
-- introduction.
--
-- Jonathan, 16 Nov 2026, on the hello to Gilis Rock Creative Studios:
-- "With the spaces already listed some will know we exist, others will
-- not. I'd like to have different emails depending on if we think they
-- know us or not. [...] If they know us I don't think we need to
-- explain who we are, we can say along the lines that we wanted to let
-- you know you can now manage and update your listing on Nomadwise,
-- and then after reconfirm what their listing url is."
--
-- 1. space_contacts.knows_us: true or false when one of us has said so
--    on the card; empty when nobody has, and then the app guesses (a
--    booking or partnership talk, or they have written to us before and
--    nothing of theirs is waiting for an answer). Most of what we know
--    about a space lives in our inboxes, not here (Gilis Rock has no
--    message on its card), so the switch is what does the work.
-- 2. The "space we know" email says what is new first, then the page.
--    The Premium one the same, with the thank-you in the middle. The
--    wording as it was is kept in outreach_templates_history.
-- 3. A WhatsApp version, so the first hello on WhatsApp, Instagram or
--    Facebook does not explain who we are to a space that knows either.
-- 4. "When we send" counts the "space we know" email as a first hello.

alter table public.space_contacts add column if not exists knows_us boolean;
comment on column public.space_contacts.knows_us is
  'They know Nomadwise already: true or false when set by hand on the card, null when not said (the app guesses). Migration 331.';

-- the card carries it
select public.pm_patch_fn('public.admin_outreach_list(text,text,integer,text,text)',
  $a$c.unsubscribed_at, c.is_test, c.topic, c.assigned_to,$a$,
  $a$c.unsubscribed_at, c.is_test, c.topic, c.knows_us, c.assigned_to,$a$,
  $a$c.knows_us$a$);

-- and it is saved with the card's other details ({"knows_us": true},
-- false, or null for "not said")
select public.pm_patch_fn('public.admin_outreach_update(uuid,jsonb)',
  $a$    space_name   = new_name,$a$,
  $a$    knows_us     = case when p ? 'knows_us' then (p->>'knows_us')::boolean else x.knows_us end,
    space_name   = new_name,$a$,
  $a$knows_us$a$);

-- "When we send": the email to a space that knows us is a first hello
select public.pm_patch_fn('public.admin_outreach_timing()',
  $a$case when m.template_key like 'invite%' then 'hello'$a$,
  $a$case when m.template_key like 'invite%' or m.template_key like 'reply\_we\_know\_you%' then 'hello'$a$,
  $a$reply\_we\_know\_you%$a$);

-- the wording as it was
insert into public.outreach_templates_history (key, name, subject, body)
select key, name, subject, body from public.outreach_templates
 where key in ('reply_we_know_you', 'reply_we_know_you_premium');

update public.outreach_templates set
  name = 'First contact: a space that knows us',
  body = $t$Hi {first_name},

I hope all is well with you and the team.

We wanted to let you know that you can now manage and update your listing on Nomadwise yourself, for free.

{claim_link}

As a reminder, your listing is here:

{page_link}

I'd be happy to answer any questions, just reply here.

{signoff}$t$,
  updated_at = now()
 where key = 'reply_we_know_you';

update public.outreach_templates set
  name = 'First contact: a space that knows us, already on Premium',
  body = $t$Hi {first_name},

I hope all is well with you and the team.

We wanted to let you know that you can now manage and update your listing on Nomadwise yourself, for free.

{claim_link}

As a thank you, we have put your listing on Nomadwise Premium, so it already has the Verified by Nomadwise badge and top positioning on your region's page. You are welcome to use the badge on your own website and in any of your marketing. It is waiting in your Owner account, under Website badges.

As a reminder, your listing is here:

{page_link}

I'd be happy to answer any questions, just reply here.

{signoff}$t$,
  updated_at = now()
 where key = 'reply_we_know_you_premium';

insert into public.outreach_templates (key, name, subject, body, stream, sort)
select 'reply_we_know_you_wa',
       'First contact: a space that knows us (WhatsApp, Instagram, Facebook)',
       'WhatsApp',
       $t$Hi, this is Jonathan from Nomadwise. I hope all is well with you and the team.

We wanted to let you know that you can now manage and update your listing for {space} on Nomadwise yourself, for free.
{claim_link}

As a reminder, your listing is here:
{page_link}

I'd be happy to answer any questions, just reply here.

{signoff}$t$,
       t.stream, t.sort
  from public.outreach_templates t
 where t.key = 'invite_listed_wa'
on conflict (key) do nothing;

-- Gilis Rock Creative Studios: Jonathan has spoken with them before.
update public.space_contacts set knows_us = true
 where id = '5534f072-67ef-432b-9335-13ea7517f2b4';
