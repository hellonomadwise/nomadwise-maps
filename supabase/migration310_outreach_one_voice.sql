-- ============================================================
-- Migration 310: the emails to listed spaces share one wording
-- ============================================================
-- Jonathan, 10 Nov 2026, on the email to Uncommon Borough ("Owner
-- account: a space we know"): "i like how this wording is, and think
-- it could be good on the other variations of scenarios, to reach out
-- to spaces where we have them listed".
--
-- The part he likes is kept word for word in each of them:
--   "<space> has a page on nomadwise.io." (the words are the link)
--   "You can now look after the page yourself, for free. Once it is
--    yours, you can keep your opening hours and details up to date,
--    and add your own photos and description, whenever it suits you:"
--   [Claim your page]
--   "Please feel free to reply here if you have any questions."
-- Only the opening lines differ, to suit why we are writing.
--
-- The wording as it was is kept in outreach_templates_history, so a
-- template can be put back.
-- ============================================================

create table if not exists public.outreach_templates_history (
  id        bigint generated always as identity primary key,
  saved_at  timestamptz not null default now(),
  key       text not null,
  name      text,
  subject   text,
  body      text
);
alter table public.outreach_templates_history enable row level security;
revoke all on table public.outreach_templates_history from public, anon, authenticated;

with new(key, subject, body) as (values

('invite_listed', 'Your page for {space} on Nomadwise',
$t$Hi {first_name},

I hope all is well with you and the team. I am Jonathan, one of the founders of Nomadwise, where remote workers and digital nomads look for good places to work from, and I wanted to share something we have been working on.

{space} has a page on nomadwise.io: {page_link}

You can now look after the page yourself, for free. Once it is yours, you can keep your opening hours and details up to date, and add your own photos and description, whenever it suits you:
{claim_link}

Please feel free to reply here if you have any questions.

{signoff}$t$),

('invite_listed_wa', 'WhatsApp',
$t$Hi, this is Jonathan from Nomadwise. I hope all is well with you and the team. {space} has a page on nomadwise.io, where remote workers and digital nomads look for good places to work from: {page_link}

You can now look after the page yourself, for free. Once it is yours, you can keep your opening hours and details up to date, and add your own photos and description, whenever it suits you: {claim_link}

{signoff}$t$),

('invite_new_page', '{space} is now on Nomadwise',
$t$Hi {first_name},

I hope all is well with you and the team. I am Jonathan, one of the founders of Nomadwise, where remote workers and digital nomads look for good places to work from.

We have just added {space}, so it now has a page on nomadwise.io: {page_link}

We put it together from publicly available information, so there is nothing you need to do, and being listed is free.

If you would like to, you can look after the page yourself, for free. Once it is yours, you can keep your opening hours and details up to date, and add your own photos and description, whenever it suits you:
{claim_link}

Please feel free to reply here if you have any questions.

{signoff}$t$),

('invite_new_page_wa', 'WhatsApp',
$t$Hi, this is Jonathan from Nomadwise. I hope all is well with you and the team. We have just added {space} to nomadwise.io, where remote workers and digital nomads look for good places to work from: {page_link}

Being listed is free, and there is nothing you need to do. If you would like to, you can look after the page yourself, for free. Once it is yours, you can keep your opening hours and details up to date, and add your own photos and description, whenever it suits you: {claim_link}

{signoff}$t$),

('reply_already_listed', 'Your page for {space} on Nomadwise',
$t$Hi {first_name},

Thank you for getting in touch, and I hope all is well with you and the team.

{space} has a page on nomadwise.io: {page_link}

About the changes you asked for: just reply with them here and I will put them on for you.

If you would rather, you can now look after the page yourself, for free. Once it is yours, you can keep your opening hours and details up to date, and add your own photos and description, whenever it suits you:
{claim_link}

Please feel free to reply here if you have any questions.

{signoff}$t$),

('reply_we_know_you_premium', 'Your page for {space} on Nomadwise',
$t$Hi {first_name},

I hope all is well with you and the team. We were in touch a while ago about {space}, and I wanted to share something we have been working on.

{space} has a page on nomadwise.io: {page_link}

As a thank you, we have put it on Nomadwise Premium, so your page already has the Verified by Nomadwise badge and top positioning on your region's page.

You can now look after the page yourself, for free. Once it is yours, you can keep your opening hours and details up to date, and add your own photos and description, whenever it suits you:
{claim_link}

Please feel free to reply here if you have any questions.

{signoff}$t$),

('claim_looked', 'Any questions about claiming {space}?',
$t$Hi {first_name},

I hope all is well with you and the team. Someone opened the claim page for {space} on Nomadwise recently. If that was you, or someone on your team, I wanted to ask whether anything was unclear, or whether you had a question before going ahead.

{space} has a page on nomadwise.io: {page_link}

You can look after the page yourself, for free. Once it is yours, you can keep your opening hours and details up to date, and add your own photos and description, whenever it suits you:
{claim_link}

If it was not you, no problem at all, and nothing changes on your page. Please feel free to reply here if you have any questions.

{signoff}$t$),

('signed_up', '{space} on Nomadwise',
$t$Hi {first_name},

I hope all is well with you. An account was made on Nomad Maps recently that looks connected to {space}, so I wanted to say hello.

{space} has a page on nomadwise.io: {page_link}

If you run {space}, you can look after the page yourself, for free. Once it is yours, you can keep your opening hours and details up to date, and add your own photos and description, whenever it suits you:
{claim_link}

If I have this wrong, no problem at all. Please feel free to reply here if you have any questions.

{signoff}$t$)

),
saved as (
  insert into public.outreach_templates_history (key, name, subject, body)
  select t.key, t.name, t.subject, t.body
    from public.outreach_templates t join new n on n.key = t.key
   where t.body is distinct from n.body or t.subject is distinct from n.subject
  returning key
)
update public.outreach_templates t
   set subject = n.subject, body = n.body
  from new n
 where t.key = n.key
   and (t.body is distinct from n.body or t.subject is distinct from n.subject);
