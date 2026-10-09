-- 179: the hello to a new page, worded better.
--
-- Jonathan, 9 Oct 2026, reading it to Level39 on his phone: "The
-- message can be worded better. Maybe starting with 'We just wanted to
-- you let you know that we've listed your coworking space on
-- Nomadwise.io...'". The template "Hello: a new page of ours (first
-- email)" (migration 178) now opens that way. It names the space
-- rather than "your coworking space", as the same words go to cafes.
-- Changed only while it still holds the words of migration 178, so an
-- edit made in Outreach > Templates is kept.
-- Pure ASCII. Safe to apply twice.

update public.outreach_templates
   set subject = '{space} is now listed on Nomadwise',
       body = 'Hi there,

We just wanted to let you know that we''ve listed {space} on nomadwise.io, the directory remote workers and digital nomads use to find places to work from. Here is your page: {page_link}

Your listing is free, and so is claiming it. Once you have claimed it, you can keep it up to date from your own Owner account: change your opening hours and contact details, and add your own photos, description and prices. You can claim it here: {claim_link}

If you would like more, Verified adds the Verified badge, a place above every free listing in your area and enquiries sent straight to your inbox, for {price_words}, monthly or yearly, cancel any time.

We will not write again unless you reply.

{signoff}',
       updated_at = now()
 where key = 'invite_new_page'
   and body = 'Hi there,

We have added {space} to nomadwise.io, where remote workers and digital nomads look for places to work from. Here is the page: {page_link}

The page is free, and so is claiming it. Once it is yours, you can update your opening hours and contact details, and add your own photos, description and prices, from your own Owner account. Claim it here: {claim_link}

If you would like more, Verified adds the Verified badge, a place above every free listing in your area and enquiries straight to your inbox, for {price_words}, monthly or yearly, cancel any time.

We will not write again unless you reply.

{signoff}';
