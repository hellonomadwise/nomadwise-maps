-- ============================================================
-- Migration 253: the owner emails as Postmark templates (step 1 of
-- Leonie's "Owner Email Setup Brief", 5 Nov 2026).
-- (Applied automatically by the build; nothing to paste.)
--
-- What this adds (nothing that sends changes here):
-- 1. public.email_templates: the original of every automatic email as
--    a Postmark template (alias, stream, subject, HTML, plain text, an
--    example to test with). Wording is today's live wording.
-- 2. Small helpers that write the house style (8px corners), so each
--    template is plain paragraphs Leonie can edit.
-- 3. pm_template_push(alias, force): puts one template into Postmark.
--    It never overwrites a template that is already there unless force
--    is true, so edits made in Postmark are never undone by a build.
--    pm_layout_push(force) does the same for the shared layout.
-- 4. pm_push_results(): reads Postmark's answers and keeps the ids.
--
-- Streams (made in Postmark on 5 Nov 2026):
--   outbound   account emails (claims, approvals, page, changes, chat)
--   lifecycle  reminders that guide owners (finish claim, sign-in)
--   enquiries  everything about enquiries, to spaces and to people
-- Safe to run twice.
-- ============================================================

create table if not exists public.email_templates (
  alias        text primary key,
  name         text not null,
  stream       text not null check (stream in ('outbound', 'lifecycle', 'enquiries')),
  for_spaces   boolean not null default true,
  subject      text not null,
  html_body    text not null,
  text_body    text not null,
  test_model   jsonb not null default '{}'::jsonb,
  sort         int not null default 100,
  postmark_id  bigint,
  push_req     bigint,
  pushed_at    timestamptz,
  push_error   text,
  live         boolean not null default false,   -- the app sends this email through the template
  updated_at   timestamptz not null default now()
);
alter table public.email_templates enable row level security;
drop policy if exists email_templates_admin on public.email_templates;
create policy email_templates_admin on public.email_templates
  for all using (public.is_admin()) with check (public.is_admin());

-- ---------- the house style, as small pieces ----------
create or replace function public.pm_p(t text) returns text language sql immutable as $$
  select '<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">' || t || '</p>' || E'\n'
$$;
create or replace function public.pm_small(t text) returns text language sql immutable as $$
  select '<p style="margin:0 0 16px;font-size:14px;line-height:1.6;color:#5C6773;">' || t || '</p>' || E'\n'
$$;
-- a link that shows its own address
create or replace function public.pm_a(var text) returns text language sql immutable as $$
  select '<a href="{{' || var || '}}" style="color:#E0442E;text-decoration:underline;">{{' || var || '}}</a>'
$$;
-- a link on words
create or replace function public.pm_aw(var text, words text) returns text language sql immutable as $$
  select '<a href="{{' || var || '}}" style="color:#E0442E;text-decoration:underline;">' || words || '</a>'
$$;
create or replace function public.pm_btn(label text, var text, note text default null) returns text language sql immutable as $$
  select '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:'
      || case when note is null then '10px 0 26px' else '8px 0 8px' end || ';">'
      || '<tr><td style="background:#E0442E;border-radius:8px;">'
      || '<a href="{{' || var || '}}" style="display:inline-block;padding:13px 22px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">'
      || label || '</a></td></tr></table>' || E'\n'
      || coalesce('<p style="margin:0 0 22px;font-size:14px;line-height:1.5;color:#5C6773;">' || note || '</p>' || E'\n', '')
$$;
-- "Jonathan / Nomadwise, https://www.nomadwise.io" in small grey (the older emails)
create or replace function public.pm_sig_short() returns text language sql immutable as $$
  select '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">Jonathan<br>Nomadwise, '
      || '<a href="https://www.nomadwise.io" style="color:#E0442E;text-decoration:underline;">https://www.nomadwise.io</a></p>' || E'\n'
$$;
-- "Kind regards, <name>, Co-founder, nomadwise.io" (the newer emails)
create or replace function public.pm_sig(who text) returns text language sql immutable as $$
  select '<p style="margin:8px 0 10px;font-size:16px;line-height:1.6;color:#142032;">Kind regards,</p>'
      || '<p style="margin:0;font-size:16px;line-height:1.4;font-weight:700;color:#142032;">' || who || '</p>'
      || '<p style="margin:2px 0 0;font-size:14px;line-height:1.5;color:#5C6773;">Co-founder, '
      || '<a href="https://www.nomadwise.io" style="color:#E0442E;font-weight:700;text-decoration:none;">nomadwise.io</a></p>' || E'\n'
$$;
create or replace function public.pm_panel(head text, body text) returns text language sql immutable as $$
  select '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 24px;">'
      || '<tr><td style="background:#F4F6F8;border-radius:8px;padding:20px 22px;">'
      || '<p style="margin:0 0 6px;font-size:15px;line-height:1.4;font-weight:700;color:#142032;">' || head || '</p>'
      || '<p style="margin:0;font-size:15px;line-height:1.6;color:#3E4C59;">' || body || '</p>'
      || '</td></tr></table>' || E'\n'
$$;
create or replace function public.pm_last(t text) returns text language sql immutable as $$
  select '<p style="margin:24px 0 0;font-size:14px;line-height:1.6;color:#5C6773;">' || t || '</p>' || E'\n'
$$;

-- ---------- the layout every template sits in ----------
create or replace function public.pm_layout_html() returns text language sql immutable as $$
  select '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Nomadwise</title></head>'
      || '<body style="margin:0;padding:0;background:#F7F8F9;">'
      || '<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;font-size:1px;line-height:1px;color:#F7F8F9;">{{preview}}'
      || repeat('&#847; &zwnj;&nbsp;', 40) || '</div>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F7F8F9;">'
      || '<tr><td align="center" style="padding:28px 16px;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">'
      || '<tr><td style="padding:0 6px 14px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;">'
      || '<span style="font-size:22px;font-weight:800;color:#E0442E;letter-spacing:-0.3px;">nomadwise</span>'
      || '{{#for_spaces}} <span style="font-size:12px;font-weight:700;color:#5C6773;letter-spacing:1.2px;margin-left:4px;">FOR SPACES</span>{{/for_spaces}}'
      || '</td></tr>'
      || '<tr><td style="background:#ffffff;border:1px solid rgba(20,32,50,0.10);border-radius:8px;padding:30px 30px 26px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;">'
      || E'\n{{{@content}}}\n'
      || '</td></tr>'
      || '<tr><td style="padding:16px 6px 0;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.6;color:#96A0AC;">'
      || 'Nomadwise, work from anywhere. Reply to this email and a person answers. '
      || '<a href="https://www.nomadwise.io" style="color:#96A0AC;">nomadwise.io</a>'
      || '{{#for_spaces}} &middot; <a href="https://nomadmaps.io/owner" style="color:#96A0AC;">Owner account</a>{{/for_spaces}}'
      || '</td></tr></table></td></tr></table></body></html>'
$$;
create or replace function public.pm_layout_text() returns text language sql immutable as $$
  select E'{{{@content}}}\n\n--\nNomadwise, work from anywhere. Reply to this email and a person answers. https://www.nomadwise.io'
$$;

-- ---------- the templates (today's live wording) ----------
-- Common model: first_name, space_name, space_kind, page_url, owner_url,
-- cta_url, preview, for_spaces. Each template lists its own extras in
-- its test_model.
create or replace function public.pm_templates_seed() returns void
language plpgsql security definer set search_path to 'public' as $seed$
declare
  owner_lines text := public.pm_p('Your Owner account: ' || public.pm_a('owner_url')
                      || '<br>Sign in with this email address; we send you a link, there is no password.');
  owner_lines_t text := E'Your Owner account: {{owner_url}}\nSign in with this email address; we send you a link, there is no password.';
  sig_t text := E'Jonathan\nNomadwise, https://www.nomadwise.io';
  sigf_t text := E'Kind regards,\nJonathan Heavens\nCo-founder, Nomadwise';
  ex jsonb := jsonb_build_object(
    'first_name', 'Marta', 'space_name', 'Casa Lumen Coworking', 'space_kind', 'coworking space',
    'page_url', 'https://www.nomadwise.io/coworking/portugal-lisbon-casa-lumen-coworking',
    'owner_url', 'https://nomadmaps.io/owner', 'cta_url', 'https://nomadmaps.io/owner',
    'for_spaces', true);
  sign_in_html text := public.pm_p('To sign in, open the link above and press "Email me a sign-in link": we send a link to {{owner_email}}, no password needed.'
                      || '{{#is_gmail}} As it is a Gmail address, "Continue with Google" works too.{{/is_gmail}}'
                      || ' After that you stay signed in on that device: bookmark nomadmaps.io/owner to come straight back.');
  sign_in_t text := 'To sign in, open the link above and press "Email me a sign-in link": we send a link to {{owner_email}}, no password needed.'
                      || '{{#is_gmail}} As it is a Gmail address, "Continue with Google" works too.{{/is_gmail}}'
                      || ' After that you stay signed in on that device: bookmark nomadmaps.io/owner to come straight back.';
  enq_lines_html text := public.pm_p('Name: {{enquiry_name}}<br>Email: {{enquiry_email}}'
                      || '{{#enquiry_phone}}<br>Phone: {{enquiry_phone}}{{/enquiry_phone}}'
                      || '{{#enquiry_want}}<br>Interested in: {{enquiry_want}}{{/enquiry_want}}'
                      || '{{#enquiry_dates}}<br>Dates: {{enquiry_dates}}{{/enquiry_dates}}'
                      || '{{#enquiry_people}}<br>People: {{enquiry_people}}{{/enquiry_people}}'
                      || '<br>Sent: {{enquiry_sent}}');
  enq_lines_t text := E'Name: {{enquiry_name}}\nEmail: {{enquiry_email}}'
                      || E'{{#enquiry_phone}}\nPhone: {{enquiry_phone}}{{/enquiry_phone}}'
                      || E'{{#enquiry_want}}\nInterested in: {{enquiry_want}}{{/enquiry_want}}'
                      || E'{{#enquiry_dates}}\nDates: {{enquiry_dates}}{{/enquiry_dates}}'
                      || E'{{#enquiry_people}}\nPeople: {{enquiry_people}}{{/enquiry_people}}'
                      || E'\nSent: {{enquiry_sent}}';
  you_sent_html text := public.pm_p('What you sent:<br>{{{message_html}}}')
                      || public.pm_p('Your details:<br>Name: {{enquiry_name}}<br>Email: {{enquiry_email}}{{#enquiry_phone}}<br>Phone: {{enquiry_phone}}{{/enquiry_phone}}');
  you_sent_t text := E'What you sent:\n{{message}}\n\nYour details:\nName: {{enquiry_name}}\nEmail: {{enquiry_email}}{{#enquiry_phone}}\nPhone: {{enquiry_phone}}{{/enquiry_phone}}';
  enq_ex jsonb := jsonb_build_object(
    'enquiry_name', 'Sam Carter', 'enquiry_first', 'Sam', 'enquiry_email', 'sam@example.com',
    'enquiry_want', 'a day pass', 'enquiry_dates', '12 to 14 Nov', 'enquiry_people', '1',
    'enquiry_sent', '5 Nov 2026',
    'message', 'Hi, do you have a desk free for three days next week? I need good wifi for calls.',
    'message_html', 'Hi, do you have a desk free for three days next week? I need good wifi for calls.');
begin
  -- one row: alias, name, stream, for_spaces, subject, html, text, model, sort
  create temporary table if not exists _t (like public.email_templates including defaults) on commit drop;
  truncate _t;

  -- 01 Claim received (Free)
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'claim-received', 'Claim received (Free)', 'outbound', 'You''ve claimed {{space_name}}',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('You''ve claimed your {{space_kind}}, {{space_name}}, on Nomadwise. Before we hand the page over we check you are with the team at {{space_name}} (usually one quick message to the business''s own Instagram, WhatsApp or email), and we email you as soon as that is done.')
 || '{{#is_new_space}}' || public.pm_p('Your {{space_kind}} is not on our map yet, so it also joins our publishing queue; we email you the link when the page is live.') || '{{/is_new_space}}'
 || '{{^is_new_space}}{{#page_url}}' || public.pm_p('Your page: ' || public.pm_a('page_url')) || '{{/page_url}}{{^page_url}}' || public.pm_p('Your page: we send the link once it is live.') || '{{/page_url}}{{/is_new_space}}'
 || public.pm_p('Your Owner account is ready to sign in to now. Once that check is done, you can update your contact details and add your own photos, description, prices and opening hours there.')
 || owner_lines || public.pm_btn('Open my Owner account', 'owner_url') || public.pm_sig_short(),
    E'Hi {{first_name}},\n\nYou''ve claimed your {{space_kind}}, {{space_name}}, on Nomadwise. Before we hand the page over we check you are with the team at {{space_name}} (usually one quick message to the business''s own Instagram, WhatsApp or email), and we email you as soon as that is done.\n\n'
 || E'{{#is_new_space}}Your {{space_kind}} is not on our map yet, so it also joins our publishing queue; we email you the link when the page is live.{{/is_new_space}}{{^is_new_space}}Your page: {{#page_url}}{{page_url}}{{/page_url}}{{^page_url}}we send the link once it is live.{{/page_url}}{{/is_new_space}}\n\n'
 || E'Your Owner account is ready to sign in to now. Once that check is done, you can update your contact details and add your own photos, description, prices and opening hours there.\n\n' || owner_lines_t || E'\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'You''ve claimed your coworking space, Casa Lumen Coworking, on Nomadwise.', 'is_new_space', false), 10);

  -- 02 Payment received (Premium)
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'payment-received', 'Payment received (Premium)', 'outbound', 'Payment received for {{space_name}}',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('You''ve claimed your {{space_kind}}, {{space_name}}, and your payment has arrived; Stripe sends the receipt separately. Next we check you are with the team at {{space_name}}, then Premium goes on and we email you.')
 || '{{#is_new_space}}' || public.pm_p('Your {{space_kind}} is new to us, so it also joins our publishing queue; we email you the link the moment the page is live.') || '{{/is_new_space}}'
 || '{{^is_new_space}}{{#page_url}}' || public.pm_p('Your page: ' || public.pm_a('page_url')) || '{{/page_url}}{{^page_url}}' || public.pm_p('Your page: (link follows once it is live)') || '{{/page_url}}{{/is_new_space}}'
 || public.pm_p('You can already sign in to your Owner account and see where things stand.')
 || owner_lines || public.pm_btn('Open my Owner account', 'owner_url') || public.pm_sig_short(),
    E'Hi {{first_name}},\n\nYou''ve claimed your {{space_kind}}, {{space_name}}, and your payment has arrived; Stripe sends the receipt separately. Next we check you are with the team at {{space_name}}, then Premium goes on and we email you.\n\n'
 || E'{{#is_new_space}}Your {{space_kind}} is new to us, so it also joins our publishing queue; we email you the link the moment the page is live.{{/is_new_space}}{{^is_new_space}}Your page: {{#page_url}}{{page_url}}{{/page_url}}{{^page_url}}(link follows once it is live){{/page_url}}{{/is_new_space}}\n\n'
 || E'You can already sign in to your Owner account and see where things stand.\n\n' || owner_lines_t || E'\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'Your payment has arrived.', 'is_new_space', false), 20);

  -- 04 Approved: Premium
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'claim-approved-premium', 'Approved: Premium', 'outbound', '{{space_name}} is now on Nomadwise Premium',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('Good news: {{space_name}} is now on Nomadwise Premium. Your page has the Verified by Nomadwise badge and top positioning on your region''s page, and enquiries sent from your page come straight to {{enquiry_address}}.')
 || '{{#page_url}}' || public.pm_p('Your page: ' || public.pm_a('page_url')) || '{{/page_url}}{{^page_url}}' || public.pm_p('Your page is in our publishing queue; we email you the link when it is live.') || '{{/page_url}}'
 || public.pm_p('Next, make the page yours: in your Owner account add your photos, your description, prices and opening hours, and if you like, an event or offer for your page. We read each change before it goes on.')
 || owner_lines || public.pm_btn('Open my Owner account', 'owner_url') || public.pm_sig_short(),
    E'Hi {{first_name}},\n\nGood news: {{space_name}} is now on Nomadwise Premium. Your page has the Verified by Nomadwise badge and top positioning on your region''s page, and enquiries sent from your page come straight to {{enquiry_address}}.\n\n'
 || E'{{#page_url}}Your page: {{page_url}}{{/page_url}}{{^page_url}}Your page is in our publishing queue; we email you the link when it is live.{{/page_url}}\n\n'
 || E'Next, make the page yours: in your Owner account add your photos, your description, prices and opening hours, and if you like, an event or offer for your page. We read each change before it goes on.\n\n' || owner_lines_t || E'\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'Casa Lumen Coworking is now on Nomadwise Premium.', 'enquiry_address', 'hello@casalumen.pt'), 30);

  -- 05 Approved: Free
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'claim-approved-free', 'Approved: Free', 'outbound', 'You now manage {{space_name}} on Nomadwise',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('Good news: we''ve confirmed you''re with {{space_name}}, so its page on Nomadwise is now yours to manage.')
 || '{{#page_url}}' || public.pm_p('Your page: ' || public.pm_a('page_url')) || '{{/page_url}}{{^page_url}}' || public.pm_p('Your page is in our publishing queue. We check every new page before it goes live, and we''ll email you the link as soon as it is.') || '{{/page_url}}'
 || public.pm_p('From your Owner account you can update your contact details and add your own photos, description, prices and opening hours. We read each change before it goes on the page.')
 || public.pm_p('When you want more, Nomadwise Premium is {{price_words}}: the Verified by Nomadwise badge, top positioning on your region''s page, unlimited enquiries straight to your inbox, and your own events and offers on your page. You will find it under Plan &amp; billing in your Owner account.')
 || owner_lines || public.pm_btn('Open my Owner account', 'owner_url') || public.pm_sig_short(),
    E'Hi {{first_name}},\n\nGood news: we''ve confirmed you''re with {{space_name}}, so its page on Nomadwise is now yours to manage.\n\n'
 || E'{{#page_url}}Your page: {{page_url}}{{/page_url}}{{^page_url}}Your page is in our publishing queue. We check every new page before it goes live, and we''ll email you the link as soon as it is.{{/page_url}}\n\n'
 || E'From your Owner account you can update your contact details and add your own photos, description, prices and opening hours. We read each change before it goes on the page.\n\n'
 || E'When you want more, Nomadwise Premium is {{price_words}}: the Verified by Nomadwise badge, top positioning on your region''s page, unlimited enquiries straight to your inbox, and your own events and offers on your page. You will find it under Plan & billing in your Owner account.\n\n' || owner_lines_t || E'\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'Casa Lumen Coworking is now yours to manage.', 'price_words', '€10 a month or €99 a year'), 40);

  -- 06 Claim not approved
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'claim-rejected', 'Claim not approved', 'outbound', 'About your claim for {{space_name}}',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('Thanks for claiming {{space_name}}. We could not confirm the claim as coming from the business, so we have not handed the page over.')
 || '{{#was_paid}}' || public.pm_p('Your payment is being refunded in full through Stripe.') || '{{/was_paid}}'
 || public.pm_p('If we have this wrong, reply to this email and tell us who you are at {{space_name}}, and we will sort it out.')
 || public.pm_sig_short(),
    E'Hi {{first_name}},\n\nThanks for claiming {{space_name}}. We could not confirm the claim as coming from the business, so we have not handed the page over.\n\n'
 || E'{{#was_paid}}Your payment is being refunded in full through Stripe.\n\n{{/was_paid}}'
 || E'If we have this wrong, reply to this email and tell us who you are at {{space_name}}, and we will sort it out.\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'About your claim for Casa Lumen Coworking.', 'was_paid', false), 50);

  -- 07 Your page is live
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'page-live', 'Your page is live', 'outbound', '{{space_name}} is live on Nomadwise',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('{{space_name}} is live on Nomadwise: ' || public.pm_a('page_url'))
 || '{{#is_premium}}' || public.pm_p('It is on Premium, with the Verified by Nomadwise badge and top positioning on your region''s page. Enquiries sent from the page go to {{enquiry_address}}.') || '{{/is_premium}}'
 || '{{^is_premium}}{{#asked_us}}' || public.pm_p('It is a free listing, built from the details you sent us and what we could confirm ourselves, with a button that sends people to you. It is in your hands now.') || '{{/asked_us}}'
 || '{{^asked_us}}' || public.pm_p('It is a free listing, built from public information, with a button that sends people to you.') || '{{/asked_us}}{{/is_premium}}'
 || public.pm_p('Have a look, and if anything is wrong or missing, fix it from your Owner account: ' || public.pm_a('owner_url') || '. Photos, your own description, prices and opening hours all go on after a quick read from us.')
 || public.pm_btn('See my page', 'page_url') || public.pm_sig_short(),
    E'Hi {{first_name}},\n\n{{space_name}} is live on Nomadwise: {{page_url}}\n\n'
 || E'{{#is_premium}}It is on Premium, with the Verified by Nomadwise badge and top positioning on your region''s page. Enquiries sent from the page go to {{enquiry_address}}.{{/is_premium}}'
 || E'{{^is_premium}}{{#asked_us}}It is a free listing, built from the details you sent us and what we could confirm ourselves, with a button that sends people to you. It is in your hands now.{{/asked_us}}{{^asked_us}}It is a free listing, built from public information, with a button that sends people to you.{{/asked_us}}{{/is_premium}}\n\n'
 || E'Have a look, and if anything is wrong or missing, fix it from your Owner account: {{owner_url}}. Photos, your own description, prices and opening hours all go on after a quick read from us.\n\nSee my page: {{page_url}}\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'Casa Lumen Coworking is live on Nomadwise.', 'is_premium', false, 'asked_us', false, 'enquiry_address', 'hello@casalumen.pt'), 60);

  -- 08 Your changes are on the page
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'changes-live', 'Your changes are on the page', 'outbound',
    '{{#page_url}}Your changes to {{space_name}} are on the page{{/page_url}}{{^page_url}}Your changes to {{space_name}} are approved{{/page_url}}',
    public.pm_p('Hi,')
 || '{{#page_url}}' || public.pm_p('Thank you for updating {{space_name}}. Your changes are going onto the page now; give it a few minutes to show.') || '{{/page_url}}'
 || '{{^page_url}}' || public.pm_p('Thank you for updating {{space_name}}. Your changes are approved and saved. They will be on your page when it goes live, and we will email you the link then.') || '{{/page_url}}'
 || public.pm_p('Anything else to change, it is all in your ' || public.pm_aw('owner_signin_url', 'Owner account') || '.')
 || sign_in_html
 || '{{#page_url}}' || public.pm_btn('See my page', 'page_url') || '{{/page_url}}{{^page_url}}' || public.pm_btn('Open my Owner account', 'owner_signin_url') || '{{/page_url}}'
 || public.pm_sig_short(),
    E'Hi,\n\n{{#page_url}}Thank you for updating {{space_name}}. Your changes are going onto the page now; give it a few minutes to show.{{/page_url}}{{^page_url}}Thank you for updating {{space_name}}. Your changes are approved and saved. They will be on your page when it goes live, and we will email you the link then.{{/page_url}}\n\n'
 || E'Anything else to change, it is all in your Owner account ({{owner_signin_url}}).\n\n' || sign_in_t || E'\n\n'
 || E'{{#page_url}}See my page: {{page_url}}{{/page_url}}{{^page_url}}Open my Owner account: {{owner_signin_url}}{{/page_url}}\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'Thank you for updating Casa Lumen Coworking.', 'owner_email', 'marta@casalumen.pt',
          'owner_signin_url', 'https://nomadmaps.io/owner?email=marta%40casalumen.pt', 'is_gmail', false), 70);

  -- 09 A quick note about your changes
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'changes-returned', 'A quick note about your changes', 'outbound', 'A quick note about your changes to {{space_name}}',
    public.pm_p('Hi,')
 || public.pm_p('Thank you for updating {{space_name}}. Before we put your changes on the page, we have a small suggestion.')
 || '{{#review_note}}' || public.pm_p('{{review_note}}') || '{{/review_note}}'
 || public.pm_p('Your changes are saved in your Owner account. Sign in, adjust them and submit again, and we will put them straight on: ' || public.pm_a('owner_signin_url'))
 || sign_in_html
 || '{{#page_url}}' || public.pm_p('Your page as it is today: ' || public.pm_a('page_url')) || '{{/page_url}}'
 || public.pm_p('Any questions, just reply to this email.')
 || public.pm_btn('Open my Owner account', 'owner_signin_url') || public.pm_sig_short(),
    E'Hi,\n\nThank you for updating {{space_name}}. Before we put your changes on the page, we have a small suggestion.\n\n{{#review_note}}{{review_note}}\n\n{{/review_note}}'
 || E'Your changes are saved in your Owner account. Sign in, adjust them and submit again, and we will put them straight on: {{owner_signin_url}}\n\n' || sign_in_t || E'\n\n'
 || E'{{#page_url}}Your page as it is today: {{page_url}}\n\n{{/page_url}}Any questions, just reply to this email.\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'Thank you for updating Casa Lumen Coworking.', 'owner_email', 'marta@casalumen.pt',
          'owner_signin_url', 'https://nomadmaps.io/owner?email=marta%40casalumen.pt', 'is_gmail', false,
          'review_note', 'Could you add a photo of the desks? The one you sent is quite dark.'), 80);

  -- 10 Premium plan ended
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'premium-ended', 'Premium plan ended', 'outbound', 'Your Premium plan for {{space_name}} has ended',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('Your Premium plan for {{space_name}} has ended, so the page is back on the free plan. It stays on Nomadwise, and you still manage it from your Owner account.')
 || '{{#page_url}}' || public.pm_p('Your page: ' || public.pm_a('page_url')) || '{{/page_url}}'
 || public.pm_p('If that is not what you meant, you can get Premium again from your Owner account at any time, or simply reply to this email.')
 || public.pm_btn('Open my Owner account', 'owner_url') || public.pm_sig_short(),
    E'Hi {{first_name}},\n\nYour Premium plan for {{space_name}} has ended, so the page is back on the free plan. It stays on Nomadwise, and you still manage it from your Owner account.\n\n'
 || E'{{#page_url}}Your page: {{page_url}}\n\n{{/page_url}}If that is not what you meant, you can get Premium again from your Owner account at any time, or simply reply to this email.\n\nOpen my Owner account: {{owner_url}}\n\n' || sig_t,
    ex || jsonb_build_object('preview', 'Your Premium plan for Casa Lumen Coworking has ended.'), 90);

  -- 13 New chat message from us
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'chat-message', 'New chat message from us', 'outbound', '{{from_name}} from Nomadwise sent you a message about {{space_name}}',
    public.pm_p('{{from_name}} from Nomadwise sent you a message about {{space_name}}:')
 || public.pm_p('{{{message_html}}}')
 || public.pm_btn('Open the chat', 'chat_url')
 || '{{#reply_by_email}}' || public.pm_small('To answer, reply to this email, or open the chat in your Owner account, under Inbox &amp; support.') || '{{/reply_by_email}}'
 || '{{^reply_by_email}}' || public.pm_small('You can answer in your Owner account, under Inbox &amp; support. If you reply to this email instead, it reaches us too.') || '{{/reply_by_email}}',
    E'{{from_name}} from Nomadwise sent you a message about {{space_name}}:\n\n{{message}}\n\n'
 || E'{{#reply_by_email}}To answer, reply to this email, or open the chat in your Owner account, under Inbox & support.{{/reply_by_email}}{{^reply_by_email}}You can answer in your Owner account, under Inbox & support. If you reply to this email instead, it reaches us too.{{/reply_by_email}}\n\nOpen the chat: {{chat_url}}',
    ex || jsonb_build_object('preview', 'Jonathan from Nomadwise sent you a message about Casa Lumen Coworking.', 'from_name', 'Jonathan',
          'message', 'Hi Marta, we added your new photos. Do you also have a day pass price we can show?',
          'message_html', 'Hi Marta, we added your new photos. Do you also have a day pass price we can show?',
          'chat_url', 'https://nomadmaps.io/owner?chat=example', 'reply_by_email', true), 130);

  -- 21 Your chat with Nomadwise (website visitor)
  insert into _t (alias, name, stream, for_spaces, subject, html_body, text_body, test_model, sort) values (
  'site-chat-reply', 'Your chat with Nomadwise (website visitor)', 'outbound', false, 'Your chat with Nomadwise',
    public.pm_p('Hi{{#first_name}} {{first_name}}{{/first_name}},')
 || public.pm_p('You wrote to us in the chat on nomadwise&#8203;.io:<br>"{{asked}}"')
 || public.pm_p('{{{message_html}}}')
 || public.pm_p('Just reply to this email if there is anything else.')
 || public.pm_small('Kind regards,<br>{{from_name}}<br>Nomadwise.io'),
    E'Hi{{#first_name}} {{first_name}}{{/first_name}},\n\nYou wrote to us in the chat on nomadwise.io:\n"{{asked}}"\n\n{{message}}\n\nJust reply to this email if there is anything else.\n\nKind regards,\n{{from_name}}\nNomadwise.io',
    jsonb_build_object('preview', 'You wrote to us in the chat on nomadwise.io.', 'for_spaces', false, 'first_name', 'Sam',
          'asked', 'Which eSIM would you recommend for Portugal?', 'from_name', 'Jonathan',
          'message', 'Hi Sam, for Portugal we would start with our guide to the best eSIMs there.',
          'message_html', 'Hi Sam, for Portugal we would start with our guide to the best eSIMs there.'), 210);

  -- ---------- lifecycle ----------
  -- 03 Finish your claim
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'finish-claim', 'Finish your claim (one reminder)', 'lifecycle', 'One more step to claim {{space_name}}',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('You started claiming <strong style="font-weight:700;">{{space_name}}</strong> on Nomadwise. There''s just one step to go.')
 || public.pm_p('Once it''s yours, you can add your own photos, keep your opening hours and prices up to date, and make sure the people who find you see your {{space_kind}} as it really is.')
 || public.pm_btn('Finish my claim', 'cta_url', 'Free, and takes about a minute.')
 || public.pm_p('If something got in the way, just reply to this email and tell me. I read every one.')
 || public.pm_sig('Jonathan')
 || public.pm_last('You''re getting this because someone started claiming {{space_name}} on nomadwise&#8203;.io with this email address. Not you? Ignore this email and nothing will change.'),
    E'Hi {{first_name}},\n\nYou started claiming {{space_name}} on Nomadwise. There''s just one step to go.\n\n'
 || E'Once it''s yours, you can add your own photos, keep your opening hours and prices up to date, and make sure the people who find you see your {{space_kind}} as it really is.\n\n'
 || E'Finish my claim: {{cta_url}}\nFree, and takes about a minute.\n\nIf something got in the way, just reply to this email and tell me. I read every one.\n\nKind regards,\nJonathan\nCo-founder, Nomadwise\n\n'
 || E'You''re getting this because someone started claiming {{space_name}} on nomadwise.io with this email address. Not you? Ignore this email and nothing will change.',
    ex || jsonb_build_object('preview', 'It''s free and takes about a minute. Here''s the link to finish.',
          'cta_url', 'https://nomadmaps.io/?claim=Casa%20Lumen%20Coworking&email=marta%40casalumen.pt'), 110);

  -- 11 Sign-in reminder 1
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'signin-reminder-1', 'Sign-in reminder 1 (day 7)', 'lifecycle', 'Your Owner account for {{space_name}} is ready',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('A quick reminder that {{space_name}} is yours to manage on Nomadwise.{{#page_url}} Your page: ' || public.pm_a('page_url') || '{{/page_url}}')
 || public.pm_p('Your Owner account is here: ' || public.pm_a('owner_url') || '<br>Sign in with this email address. There is no password: we send you a sign-in link.')
 || public.pm_p('Once you are in, you can update your opening hours and contact details, and add your own photos, description and prices.')
 || public.pm_p('If anything is unclear, just reply to this email.')
 || public.pm_btn('Open my Owner account', 'owner_url')
 || public.pm_small('Jonathan'),
    E'Hi {{first_name}},\n\nA quick reminder that {{space_name}} is yours to manage on Nomadwise.{{#page_url}} Your page: {{page_url}}{{/page_url}}\n\n'
 || E'Your Owner account is here: {{owner_url}}\nSign in with this email address. There is no password: we send you a sign-in link.\n\n'
 || E'Once you are in, you can update your opening hours and contact details, and add your own photos, description and prices.\n\nIf anything is unclear, just reply to this email.\n\nJonathan',
    ex || jsonb_build_object('preview', 'A quick reminder that Casa Lumen Coworking is yours to manage on Nomadwise.'), 120);

  -- 12 Sign-in reminder 2
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'signin-reminder-2', 'Sign-in reminder 2 (day 21, last)', 'lifecycle', 'Anything we can help with for {{space_name}}?',
    public.pm_p('Hi {{first_name}},')
 || public.pm_p('Just checking in on {{space_name}}. It looks like you haven''t had a chance to sign in to your Owner account yet. If something got in the way, reply to this email and I will sort it out.')
 || public.pm_p('Once you are in, you can keep your hours, prices and contact details up to date, and add your own photos and description, so nomads see {{space_name}} at its best.')
 || public.pm_btn('Open my Owner account', 'owner_url')
 || public.pm_small('Jonathan'),
    E'Hi {{first_name}},\n\nJust checking in on {{space_name}}. It looks like you haven''t had a chance to sign in to your Owner account yet. If something got in the way, reply to this email and I will sort it out.\n\n'
 || E'Once you are in, you can keep your hours, prices and contact details up to date, and add your own photos and description, so nomads see {{space_name}} at its best.\n\nOpen my Owner account: {{owner_url}}\n\nJonathan',
    ex || jsonb_build_object('preview', 'Just checking in on Casa Lumen Coworking.'), 125);

  -- ---------- enquiries ----------
  -- 14 New enquiry for your space
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'enquiry-to-space', 'New enquiry for your space', 'enquiries', '{{subject_prefix}}New enquiry for {{space_name}} from Nomadwise',
    public.pm_p('Hi {{space_name}} team,')
 || public.pm_p('You have a new enquiry from a remote worker who found {{#page_url}}your page on Nomadwise: ' || public.pm_a('page_url') || '{{/page_url}}{{^page_url}}you on Nomadwise.{{/page_url}}')
 || enq_lines_html
 || public.pm_p('Their message:<br>{{{message_html}}}')
 || public.pm_p('To reply, simply answer this email. Your reply goes directly to {{enquiry_first}}.')
 || '{{#is_released}}' || public.pm_panel('About this enquiry', 'We kept this enquiry for you while your free enquiries were used up. Your page is on Premium now, so every enquiry comes straight to you.') || '{{/is_released}}'
 || '{{#is_free_slot}}' || public.pm_panel('About your listing', 'With Nomadwise Premium, you can receive an unlimited number of enquiries straight to your inbox, along with other benefits for your page. This was free enquiry {{free_used}} of {{free_limit}} included with your free plan.')
     || public.pm_p('See everything Premium includes: ' || public.pm_a('premium_url')) || '{{/is_free_slot}}'
 || '{{#is_premium_no_address}}' || public.pm_p('Your Premium page does not have an enquiry address yet. Add one in your Owner account and future enquiries will reach you directly:<br>' || public.pm_a('owner_url')) || '{{/is_premium_no_address}}'
 || '{{#is_unclaimed}}' || public.pm_panel('About your listing', '{{space_name}} is listed on Nomadwise free of charge, based on publicly available information. You can claim the page at no cost to keep your details up to date and add your own photos, prices and opening hours:')
     || public.pm_btn('Claim your page', 'claim_url') || '{{/is_unclaimed}}'
 || '{{#is_claimed_free}}' || public.pm_panel('About your listing', 'With Nomadwise Premium, you can receive an unlimited number of enquiries straight to your inbox, along with other benefits for your page.')
     || public.pm_p('See everything Premium includes: ' || public.pm_a('premium_url')) || '{{/is_claimed_free}}'
 || public.pm_sig('Jonathan Heavens'),
    E'Hi {{space_name}} team,\n\nYou have a new enquiry from a remote worker who found {{#page_url}}your page on Nomadwise: {{page_url}}{{/page_url}}{{^page_url}}you on Nomadwise.{{/page_url}}\n\n'
 || enq_lines_t || E'\n\nTheir message:\n{{message}}\n\nTo reply, simply answer this email. Your reply goes directly to {{enquiry_first}}.\n\n'
 || E'{{#is_released}}About this enquiry\nWe kept this enquiry for you while your free enquiries were used up. Your page is on Premium now, so every enquiry comes straight to you.\n\n{{/is_released}}'
 || E'{{#is_free_slot}}About your listing\nWith Nomadwise Premium, you can receive an unlimited number of enquiries straight to your inbox, along with other benefits for your page. This was free enquiry {{free_used}} of {{free_limit}} included with your free plan.\n\nSee everything Premium includes: {{premium_url}}\n\n{{/is_free_slot}}'
 || E'{{#is_premium_no_address}}Your Premium page does not have an enquiry address yet. Add one in your Owner account and future enquiries will reach you directly:\n{{owner_url}}\n\n{{/is_premium_no_address}}'
 || E'{{#is_unclaimed}}About your listing\n{{space_name}} is listed on Nomadwise free of charge, based on publicly available information. You can claim the page at no cost to keep your details up to date and add your own photos, prices and opening hours:\n{{claim_url}}\n\n{{/is_unclaimed}}'
 || E'{{#is_claimed_free}}About your listing\nWith Nomadwise Premium, you can receive an unlimited number of enquiries straight to your inbox, along with other benefits for your page.\n\nSee everything Premium includes: {{premium_url}}\n\n{{/is_claimed_free}}'
 || sigf_t,
    ex || enq_ex || jsonb_build_object('preview', 'You have a new enquiry from a remote worker who found your page on Nomadwise.',
          'subject_prefix', '', 'is_free_slot', true, 'free_used', 1, 'free_limit', 2,
          'premium_url', 'https://nomadmaps.io/?owner&billing', 'claim_url', 'https://nomadmaps.io/?claim=portugal-lisbon-casa-lumen-coworking',
          'is_released', false, 'is_premium_no_address', false, 'is_unclaimed', false, 'is_claimed_free', false), 140);

  -- 15 An enquiry is waiting for you
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'enquiry-waiting', 'An enquiry is waiting for you (free enquiries used)', 'enquiries', 'A new enquiry for {{space_name}} is waiting for you',
    public.pm_p('Hi {{greeting_name}},')
 || public.pm_p('A remote worker has just sent {{space_name}} an enquiry through your page on Nomadwise.')
 || '{{#asked_html}}' || public.pm_p('What they asked:<br>{{{asked_html}}}')
     || public.pm_p('Their name{{#has_extra}}, email and message{{/has_extra}}{{^has_extra}} and email{{/has_extra}} come with Nomadwise Premium.') || '{{/asked_html}}'
 || '{{^asked_html}}' || public.pm_p('Their message, name and email come with Nomadwise Premium.') || '{{/asked_html}}'
 || public.pm_p('Your free plan includes {{free_limit}} enquiries, which you have now received. With Nomadwise Premium, you can receive an unlimited number of enquiries straight to your inbox, including this one, as well as the Verified by Nomadwise badge and top positioning on your region''s page.')
 || public.pm_p('If you have any questions, simply reply to this email.')
 || public.pm_btn('Get Premium', 'premium_url') || public.pm_sig('Jonathan Heavens'),
    E'Hi {{greeting_name}},\n\nA remote worker has just sent {{space_name}} an enquiry through your page on Nomadwise.\n\n'
 || E'{{#asked}}What they asked:\n{{asked}}\n\nTheir name{{#has_extra}}, email and message{{/has_extra}}{{^has_extra}} and email{{/has_extra}} come with Nomadwise Premium.{{/asked}}{{^asked}}Their message, name and email come with Nomadwise Premium.{{/asked}}\n\n'
 || E'Your free plan includes {{free_limit}} enquiries, which you have now received. With Nomadwise Premium, you can receive an unlimited number of enquiries straight to your inbox, including this one, as well as the Verified by Nomadwise badge and top positioning on your region''s page.\n\n'
 || E'If you have any questions, simply reply to this email.\n\nGet Premium: {{premium_url}}\n\n' || sigf_t,
    ex || jsonb_build_object('preview', 'A remote worker has just sent Casa Lumen Coworking an enquiry.', 'greeting_name', 'Marta',
          'free_limit', 2, 'premium_url', 'https://nomadmaps.io/?owner&billing', 'asked', '', 'asked_html', '', 'has_extra', false), 150);

  -- 16 Enquiry to a Premium space (its own enquiry address)
  insert into _t (alias, name, stream, subject, html_body, text_body, test_model, sort) values (
  'enquiry-premium-direct', 'Enquiry to a Premium space', 'enquiries', 'Enquiry for {{space_name}} from Nomadwise',
    public.pm_p('New enquiry for {{space_name}}, sent from your page on Nomadwise.')
 || public.pm_p('From: {{enquiry_name}} &lt;{{enquiry_email}}&gt;{{#enquiry_phone}}<br>Phone: {{enquiry_phone}}{{/enquiry_phone}}<br>About: {{enquiry_about}}'
     || '{{#enquiry_dates}}<br>Dates: {{enquiry_dates}}{{/enquiry_dates}}{{#enquiry_people}}<br>People: {{enquiry_people}}{{/enquiry_people}}')
 || public.pm_p('{{{message_html}}}')
 || public.pm_p('Reply to this email to answer {{enquiry_name}} directly.')
 || public.pm_small('Nomadwise, ' || public.pm_a('page_url')),
    E'New enquiry for {{space_name}}, sent from your page on Nomadwise.\n\nFrom:     {{enquiry_name}} <{{enquiry_email}}>\n{{#enquiry_phone}}Phone:    {{enquiry_phone}}\n{{/enquiry_phone}}About:    {{enquiry_about}}\n{{#enquiry_dates}}Dates:    {{enquiry_dates}}\n{{/enquiry_dates}}{{#enquiry_people}}People:   {{enquiry_people}}\n{{/enquiry_people}}\n{{message}}\n\nReply to this email to answer {{enquiry_name}} directly.\n\nNomadwise, {{page_url}}',
    ex || enq_ex || jsonb_build_object('preview', 'New enquiry for Casa Lumen Coworking.', 'enquiry_about', 'A day pass'), 160);

  -- 17 We have your request (remote worker)
  insert into _t (alias, name, stream, for_spaces, subject, html_body, text_body, test_model, sort) values (
  'enquiry-received-nomad', 'We have your request (remote worker)', 'enquiries', false,
    '{{subject_prefix}}We have your request{{#space_name}} for {{space_name}}{{/space_name}}',
    public.pm_p('Hi {{greeting_name}},')
 || public.pm_p('Thank you for your request on Nomadwise. We have received it and will pass it on to {{space_or_the_space}}. We will email you again as soon as it is with them, and their reply will come straight to your email address.')
 || you_sent_html
 || public.pm_p('If anything needs changing, or you would like to add something, simply reply to this email.')
 || public.pm_sig('Jonathan Heavens'),
    E'Hi {{greeting_name}},\n\nThank you for your request on Nomadwise. We have received it and will pass it on to {{space_or_the_space}}. We will email you again as soon as it is with them, and their reply will come straight to your email address.\n\n'
 || you_sent_t || E'\n\nIf anything needs changing, or you would like to add something, simply reply to this email.\n\n' || sigf_t,
    enq_ex || jsonb_build_object('preview', 'Thank you for your request on Nomadwise.', 'for_spaces', false, 'subject_prefix', '',
          'greeting_name', 'Sam', 'space_name', 'Casa Lumen Coworking', 'space_or_the_space', 'Casa Lumen Coworking'), 170);

  -- 18 Your request has been sent (remote worker)
  insert into _t (alias, name, stream, for_spaces, subject, html_body, text_body, test_model, sort) values (
  'enquiry-sent-nomad', 'Your request has been sent (remote worker)', 'enquiries', false,
    '{{subject_prefix}}Your request has been sent to {{#one_space}}{{space_name}}{{/one_space}}{{^one_space}}{{space_count}} spaces{{/one_space}}',
    public.pm_p('Hi {{greeting_name}},')
 || '{{#one_space}}'
 || public.pm_p('Thank you for your request on Nomadwise. We have sent it to {{space_name}}, and their reply will come straight to your email address.')
 || you_sent_html
 || '{{#website}}' || public.pm_p('If you would like to contact them yourself as well, their website is ' || public.pm_a('website')) || '{{/website}}'
 || '{{/one_space}}'
 || '{{^one_space}}'
 || public.pm_p('Thank you for your request on Nomadwise. We have sent it to these {{space_count}} spaces:')
 || public.pm_p('{{{spaces_html}}}')
 || public.pm_p('Their replies will come straight to your email address.{{#any_website}} If you would like to contact any of them yourself, their websites are listed above.{{/any_website}}')
 || '{{/one_space}}'
 || public.pm_p('If you have any further questions, simply reply to this email.')
 || public.pm_sig('Jonathan Heavens'),
    E'Hi {{greeting_name}},\n\n{{#one_space}}Thank you for your request on Nomadwise. We have sent it to {{space_name}}, and their reply will come straight to your email address.\n\n' || you_sent_t
 || E'\n\n{{#website}}If you would like to contact them yourself as well, their website is {{website}}\n\n{{/website}}{{/one_space}}'
 || E'{{^one_space}}Thank you for your request on Nomadwise. We have sent it to these {{space_count}} spaces:\n\n{{spaces_text}}\n\nTheir replies will come straight to your email address.{{#any_website}} If you would like to contact any of them yourself, their websites are listed above.{{/any_website}}\n\n{{/one_space}}'
 || E'If you have any further questions, simply reply to this email.\n\n' || sigf_t,
    enq_ex || jsonb_build_object('preview', 'Thank you for your request on Nomadwise.', 'for_spaces', false, 'subject_prefix', '',
          'greeting_name', 'Sam', 'one_space', true, 'space_name', 'Casa Lumen Coworking', 'space_count', 1,
          'website', 'https://casalumen.pt', 'spaces_html', '', 'spaces_text', '', 'any_website', false), 180);

  -- 19 We could not pass it on (remote worker)
  insert into _t (alias, name, stream, for_spaces, subject, html_body, text_body, test_model, sort) values (
  'enquiry-unreachable-nomad', 'We could not pass it on (remote worker)', 'enquiries', false, 'Your request for {{space_name}}',
    public.pm_p('Hi {{greeting_name}},')
 || public.pm_p('Thanks for your request about {{space_name}} on nomadwise&#8203;.io. We could not find a way to pass it on to them, so the quickest way to get an answer is to contact them directly{{#ways_html}}:{{/ways_html}}{{^ways_html}}.{{/ways_html}}')
 || '{{#ways_html}}' || public.pm_p('{{{ways_html}}}') || '{{/ways_html}}'
 || public.pm_p('Sorry we could not do more this time.')
 || public.pm_small('Jonathan<br>Nomadwise'),
    E'Hi {{greeting_name}},\n\nThanks for your request about {{space_name}} on nomadwise.io. We could not find a way to pass it on to them, so the quickest way to get an answer is to contact them directly{{#ways}}:\n\n{{ways}}{{/ways}}{{^ways}}.{{/ways}}\n\nSorry we could not do more this time.\n\nJonathan\nNomadwise',
    jsonb_build_object('preview', 'Thanks for your request about Casa Lumen Coworking.', 'for_spaces', false, 'greeting_name', 'Sam',
          'space_name', 'Casa Lumen Coworking', 'ways', E'Website: https://casalumen.pt\nInstagram: @casalumen',
          'ways_html', 'Website: https://casalumen.pt<br>Instagram: @casalumen'), 190);

  -- 20 Did you find a place to work? (remote worker)
  insert into _t (alias, name, stream, for_spaces, subject, html_body, text_body, test_model, sort) values (
  'enquiry-followup-nomad', 'Did you find a place to work? (remote worker)', 'enquiries', false, 'Did you find a place to work?',
    public.pm_p('Hi {{greeting_name}},')
 || public.pm_p('A few days ago you asked {{space_names}} on nomadwise&#8203;.io about working there. Did you find a place?')
 || public.pm_p('It takes one tap to tell us. It helps us know which spaces reply, so we can point other remote workers the right way.')
 || public.pm_p('If you have any questions, simply reply to this email.')
 || public.pm_btn('Tell us where you went', 'cta_url') || public.pm_sig('Jonathan Heavens'),
    E'Hi {{greeting_name}},\n\nA few days ago you asked {{space_names}} on nomadwise.io about working there. Did you find a place?\n\nIt takes one tap to tell us. It helps us know which spaces reply, so we can point other remote workers the right way.\n\nIf you have any questions, simply reply to this email.\n\nTell us where you went: {{cta_url}}\n\n' || sigf_t,
    jsonb_build_object('preview', 'Did you find a place?', 'for_spaces', false, 'greeting_name', 'Sam',
          'space_names', 'Casa Lumen Coworking', 'cta_url', 'https://nomadmaps.io/?found=example'), 200);

  -- copy in; never touch the Postmark ids or the live switch
  insert into public.email_templates (alias, name, stream, for_spaces, subject, html_body, text_body, test_model, sort)
  select alias, name, stream, for_spaces, subject, html_body, text_body, test_model, sort from _t
  on conflict (alias) do update
     set name = excluded.name, stream = excluded.stream, for_spaces = excluded.for_spaces,
         subject = excluded.subject, html_body = excluded.html_body, text_body = excluded.text_body,
         test_model = excluded.test_model, sort = excluded.sort, updated_at = now();
end $seed$;

select public.pm_templates_seed();

-- ---------- putting them into Postmark (only when asked) ----------
create or replace function public.pm_token() returns text
language sql stable security definer set search_path to 'public' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'postmark_server_token' limit 1
$$;

create or replace function public.pm_layout_push(p_force boolean default false) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare
  req bigint;
  body jsonb := jsonb_build_object(
    'Name', 'Nomadwise email layout', 'Alias', 'nomadwise-layout', 'TemplateType', 'Layout',
    'HtmlBody', public.pm_layout_html(), 'TextBody', public.pm_layout_text());
begin
  if p_force then
    select net.http_request(
      url := 'https://api.postmarkapp.com/templates/nomadwise-layout', method := 'PUT', body := body,
      headers := jsonb_build_object('X-Postmark-Server-Token', public.pm_token(),
                                    'Accept', 'application/json', 'Content-Type', 'application/json'))
      into req;
  else
    select net.http_post(
      url := 'https://api.postmarkapp.com/templates', body := body,
      headers := jsonb_build_object('X-Postmark-Server-Token', public.pm_token(),
                                    'Accept', 'application/json', 'Content-Type', 'application/json'))
      into req;
  end if;
  return req;
end $$;

-- Puts one template into Postmark. Creates it when new. Only replaces
-- what is in Postmark when p_force is true (edits in Postmark win).
create or replace function public.pm_template_push(p_alias text, p_force boolean default false) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare
  t   public.email_templates%rowtype;
  req bigint;
  body jsonb;
begin
  select * into t from public.email_templates where alias = p_alias;
  if not found then raise exception 'No template %', p_alias; end if;
  if t.postmark_id is not null and not p_force then return null; end if;
  body := jsonb_build_object(
    'Name', case when t.live then t.name else '[Not live yet] ' || t.name end,
    'Alias', t.alias, 'TemplateType', 'Standard', 'LayoutTemplate', 'nomadwise-layout',
    'Subject', t.subject, 'HtmlBody', t.html_body, 'TextBody', t.text_body);
  if t.postmark_id is null then
    select net.http_post(url := 'https://api.postmarkapp.com/templates', body := body,
      headers := jsonb_build_object('X-Postmark-Server-Token', public.pm_token(),
                                    'Accept', 'application/json', 'Content-Type', 'application/json'))
      into req;
  else
    select net.http_request(url := 'https://api.postmarkapp.com/templates/' || t.alias, method := 'PUT', body := body,
      headers := jsonb_build_object('X-Postmark-Server-Token', public.pm_token(),
                                    'Accept', 'application/json', 'Content-Type', 'application/json'))
      into req;
  end if;
  update public.email_templates set push_req = req, pushed_at = now(), push_error = null where alias = p_alias;
  return req;
end $$;

-- Reads Postmark's answers to the pushes and keeps the template ids.
create or replace function public.pm_push_results() returns table(alias text, status int, template_id bigint, error text)
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.email_templates t
     set postmark_id = coalesce((r.content::jsonb ->> 'TemplateId')::bigint, t.postmark_id),
         push_error = case when r.status_code between 200 and 299 then null else left(r.content::text, 300) end
    from net._http_response r
   where r.id = t.push_req;
  return query
    select t.alias, r.status_code, t.postmark_id, t.push_error
      from public.email_templates t left join net._http_response r on r.id = t.push_req
     order by t.sort;
end $$;
