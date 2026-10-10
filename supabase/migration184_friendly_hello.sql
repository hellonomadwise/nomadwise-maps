-- 184: the hello to a new page, friendlier and without the sales line.
--
-- Jonathan, 10 Oct 2026, reading the hello to Level39: "this needs
-- rewriting, I think its too salesy, i know its good to mention
-- pricing here, but im unsure about it. also how it just adds "Cancel
-- any time", it doesn't flow. I want it to be communicated as though
-- we are friendly, we've done a nice thing and they can claim and
-- manage their listing if they wish".
-- The template "Hello: a new page of ours (first email)" now tells them
-- what we did, that being listed is free, that they can claim the page
-- if they wish, and mentions Verified once, lightly, with no price: the
-- details are in the Owner account. Changed only while it still holds
-- our own wording, so an edit made in Outreach > Templates is kept.
-- Pure ASCII. Safe to apply twice.

update public.outreach_templates
   set subject = '{space} is now on Nomadwise',
       body = 'Hi there,

We just wanted to let you know that we''ve added {space} to nomadwise.io, where remote workers and digital nomads look for good places to work from. Here is your page: {page_link}

We put it together from publicly available information, so there is nothing you need to do, and being listed is free.

If you would like to make the page your own, you can claim it at no cost. You will then have your own Owner account, where you can update your opening hours and contact details and add your own photos, description and prices whenever it suits you:

{claim_link}

If you ever want a little extra visibility, there is also an optional Verified listing, and you will find the details in your Owner account.

We hope it helps a few more people find you.

{signoff}',
       updated_at = now()
 where key = 'invite_new_page'
   and body like 'Hi there,%We just wanted to let you know that we''ve listed {space} on nomadwise.io%';
