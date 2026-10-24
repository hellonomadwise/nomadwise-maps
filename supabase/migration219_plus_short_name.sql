-- ============================================================
-- Migration 219: "Plus", not "Nomadwise Plus", where the reader already
-- knows the plan.
-- (Applied automatically by the build; nothing to paste.)
--
-- CR-30. Jonathan, 24 Oct: the two plans are Free and Plus; the full
-- name "Nomadwise Plus" only where it introduces the plan. Migration
-- 217 used the full name almost everywhere. Changed here to "Plus":
--   * payment received ("then Plus goes on") and Plus approved (body)
--   * Plus plan ended (subject and body)
--   * "your page is live" for a Plus page
--   * an enquiry for a Plus page with no enquiry address
--   * the claim page message "This listing is already on Plus."
--   * the site chat ("free or Plus"; a Plus listing)
--   * Outreach templates: "choose Free or Plus"
-- Kept as "Nomadwise Plus": the Plus approved subject, the free
-- claim approved paragraph, the claim reminder, the free-enquiry line,
-- the red email button "See Nomadwise Plus", the first mention in
-- Outreach templates and in the site chat.
-- Each function below is its migration 217 version with only these
-- swaps. Pure ASCII. Safe to apply twice.
-- ============================================================

-- claim_emails: from migration 217, wording only.
create or replace function public.claim_emails()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  space   text;
  kind_of text;
  first   text;
  url     text;
  subj    text;
  body    text;
  kind    text;
  v_city  text;
  sig     text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
  owner_line text := E'\n\nYour Owner account: https://nomadmaps.io/owner\n'
                  || 'Sign in with this email address; we send you a link, there is no password.';
  cta_label text;
  cta_url   text;
begin
  if new.owner_email is null or new.owner_email = '' then return new; end if;

  space := coalesce(nullif(new.space_name, ''),
                    (select v.name from public.venues v where v.id = new.venue_id),
                    'your space');
  kind_of := public.space_kind(coalesce(
               (select v.type from public.venues v where v.id = new.venue_id), new.space_type));
  v_city := coalesce(nullif((select v.city from public.venues v where v.id = new.venue_id), ''),
                    nullif(new.space_city, ''), 'your city');
  first := coalesce(nullif(split_part(trim(coalesce(new.owner_name, '')), ' ', 1), ''), 'there');
  url   := public.owner_page_url(new.venue_id);

  -- Free claim just made.
  if tg_op = 'INSERT' and new.status = 'free_pending' then
    kind := 'claim_received';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'You''ve claimed ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'You''ve claimed your ' || kind_of || ', ' || space || ', on Nomadwise. '
         || 'Before we hand the page over we check you are with the team at ' || space || ' '
         || '(usually one quick message to the business''s own Instagram, WhatsApp or '
         || 'email), and we email you as soon as that is done.' || E'\n\n'
         || case when new.is_new_space
                 then 'Your ' || kind_of || ' is not on our map yet, so it also joins our '
                      || 'publishing queue; we email you the link when the page is live.'
                 else 'Your page: ' || coalesce(url, 'we send the link once it is live.') end
         || E'\n\n'
         || 'Your Owner account is ready to sign in to now. Once that check is done, '
         || 'you can update your contact details and add your own photos, description, prices and '
         || 'opening hours there.'
         || owner_line || sig;

  -- Payment landed, claim waiting for us.
  elsif tg_op = 'UPDATE' and old.status = 'started' and new.status = 'awaiting_approval' then
    kind := 'payment_received';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'Payment received for ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'You''ve claimed your ' || kind_of || ', ' || space || ', and your '
         || 'payment has arrived; Stripe sends the receipt separately. Next we check you '
         || 'are with the team at ' || space || ', then Plus goes on and we email you.' || E'\n\n'
         || case when new.is_new_space
                 then 'Your ' || kind_of || ' is new to us, so it also joins our publishing '
                      || 'queue; we email you the link the moment the page is live.'
                 else 'Your page: ' || coalesce(url, '(link follows once it is live)') end
         || E'\n\n'
         || 'You can already sign in to your Owner account and see where things stand.'
         || owner_line || sig;

  -- Verified claim approved.
  elsif tg_op = 'UPDATE' and old.status = 'awaiting_approval' and new.status = 'paid' then
    kind := 'approved_verified';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := space || ' is now on Nomadwise Plus';
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Done: ' || space || ' is now on Plus. Your page has the Verified '
         || 'by Nomadwise badge and top positioning on your region''s page, and '
         || 'enquiries sent from your page come straight to '
         || coalesce(nullif(new.enquiry_email, ''), new.owner_email) || '.' || E'\n\n'
         || case when url is not null then 'Your page: ' || url || E'\n\n'
                 else 'Your page is in our publishing queue; we email you the link when it is live.' || E'\n\n' end
         || 'Next, make the page yours: in your Owner account add your photos, your '
         || 'description, prices and opening hours, and if you like, an event or offer '
         || 'for your page. We read each change before it goes on.'
         || owner_line || sig;

  -- Free claim approved.
  elsif tg_op = 'UPDATE' and old.status = 'free_pending' and new.status = 'free' then
    kind := 'approved_free';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'You now manage ' || space || ' on Nomadwise';
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Done: we have confirmed you are with ' || space || ', and you now manage its '
         || 'page on Nomadwise.' || E'\n\n'
         || case when url is not null then 'Your page: ' || url || E'\n\n'
                 else 'The page is in our publishing queue; we check every new page before '
                      || 'it goes live and will email you the link.' || E'\n\n' end
         || 'From your Owner account you can update your contact details and add your own '
         || 'photos, description, prices and opening hours. We read each change before '
         || 'it goes on the page.' || E'\n\n'
         || 'When you want more, Nomadwise Plus is '
         || public.verified_price_words(coalesce((select country from public.venues where id = new.venue_id), new.space_country))
         || ': the Verified by Nomadwise badge, top positioning on your region''s '
         || 'page, unlimited enquiries straight to your inbox, and your own events and '
         || 'offers on your page. You will find it under Plan & billing in your Owner '
         || 'account.'
         || owner_line || sig;

  -- Rejected.
  elsif tg_op = 'UPDATE' and new.status = 'rejected' and old.status in ('awaiting_approval', 'free_pending') then
    kind := 'rejected';
    subj := 'About your claim for ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks for claiming ' || space || '. We could not confirm the claim as coming '
         || 'from the business, so we have not handed the page over.'
         || case when old.status = 'awaiting_approval'
                 then E'\n\n' || 'Your payment is being refunded in full through Stripe.'
                 else '' end
         || E'\n\n'
         || 'If we have this wrong, reply to this email and tell us who you are at '
         || space || ', and we will sort it out.'
         || sig;
  else
    return new;
  end if;

  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);
  return new;
exception when others then
  -- Never silent again: a failure here shows in Emails to owners.
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, error)
    values ('claim_email', coalesce(lower(new.owner_email), '?'),
            'Claim email for ' || coalesce(new.space_name, 'a space'),
            new.id::text, 'failed', left(sqlerrm, 300));
  exception when others then null; end;
  return new;
end $$;

-- plan_ended: from migration 217, wording only.
create or replace function public.plan_ended(p_venue uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v     public.venues%rowtype;
  first text;
  url   text;
  body  text;
begin
  select * into v from public.venues where id = p_venue;
  if not found then return; end if;

  perform public.notify_phone(
    'Plus ended: ' || v.name,
    'Subscription ' || coalesce(p_reason, 'ended') || '; the page is back to free.'
      || case when coalesce(v.listing_owner_email, '') <> ''
              then ' The owner has been emailed.' else ' No owner on record to tell.' end,
    'moneybag');

  if coalesce(v.listing_owner_email, '') = '' then return; end if;
  -- One email per ending: not again for the same venue within a day.
  if exists (select 1 from public.owner_emails e
              where e.kind = 'plan_ended' and e.ref = v.id::text
                and e.created_at > now() - interval '1 day') then
    return;
  end if;

  first := coalesce(nullif(split_part(trim(coalesce(v.listing_owner_name, '')), ' ', 1), ''), 'there');
  url := public.owner_page_url(v.id);
  body := 'Hi ' || first || ',' || E'\n\n'
       || 'Your Plus plan for ' || v.name || ' has ended, so the page is back on '
       || 'the free plan. It stays on Nomadwise, and you still manage it from your Owner '
       || 'account.' || E'\n\n'
       || case when url is not null then 'Your page: ' || url || E'\n\n' else '' end
       || 'If that is not what you meant, you can get Plus again from your Owner '
       || 'account at any time, or simply reply to this email.'
       || E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
  perform public.send_owner_email(v.listing_owner_email,
                                  'Your Plus plan for ' || v.name || ' has ended',
                                  body, 'plan_ended', v.id::text,
                                  'Open my Owner account', 'https://nomadmaps.io/owner');
exception when others then
  null;
end $$;

-- page_live_email: from migration 217, wording only.
create or replace function public.page_live_email()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  first text;
  url   text;
  body  text;
  asked boolean;
  sig   text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
begin
  if tg_op <> 'UPDATE' then return new; end if;
  if coalesce(new.listing_owner_email, '') = '' then return new; end if;
  if new.website_status <> 'released' then return new; end if;
  if coalesce(old.website_status, '') = 'released' then return new; end if;
  if new.webflow_slug is null or new.webflow_slug = '' then return new; end if;
  if exists (select 1 from public.owner_emails e
              where e.kind = 'page_live' and e.ref = new.id::text
                and e.status = 'sent') then
    return new;
  end if;

  -- Did the owner ask us to add the space (a claim for a space that
  -- was not listed yet)? Then the page started from what they sent.
  asked := exists (select 1 from public.listing_claims c
                    where c.venue_id = new.id
                      and c.is_new_space
                      and c.status not in ('abandoned', 'rejected'));

  first := coalesce(nullif(split_part(trim(coalesce(new.listing_owner_name, '')), ' ', 1), ''), 'there');
  url := 'https://www.nomadwise.io/coworking/' || new.webflow_slug;
  body := 'Hi ' || first || ',' || E'\n\n'
       || new.name || ' is live on Nomadwise: ' || url || E'\n\n'
       || case when new.listing_tier = 'verified'
               then 'It is on Plus, with the Verified by Nomadwise badge and top '
                    || 'positioning on your region''s page. Enquiries sent '
                    || 'from the page go to '
                    || coalesce(nullif(new.listing_enquiry_email, ''), new.listing_owner_email) || '.'
               when asked
               then 'It is a free listing, built from the details you sent us and what we '
                    || 'could confirm ourselves, with a button that sends people to you. '
                    || 'It is in your hands now.'
               else 'It is a free listing, built from public information, with a button '
                    || 'that sends people to you.' end
       || E'\n\n'
       || 'Have a look, and if anything is wrong or missing, fix it from your Owner '
       || 'account: https://nomadmaps.io/owner. Photos, your own description, prices '
       || 'and opening hours all go on after a quick read from us.'
       || sig;
  perform public.send_owner_email(new.listing_owner_email,
                                  new.name || ' is live on Nomadwise',
                                  body, 'page_live', new.id::text,
                                  'See my page', url);
  return new;
exception when others then
  return new;
end $$;

-- enquiry_space_email: from migration 217, wording only.
create or replace function public.enquiry_space_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  page  text;
  pitch text;
  first text;
  used  int;
  lim   int;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;

  page := case when v.webflow_slug is not null
               then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  first := nullif(nullif(split_part(trim(e.name), ' ', 1), ''), 'Someone');

  if e.held_at is not null then
    -- Kept while the free enquiries were used up, sent now on Plus.
    pitch := 'About this enquiry' || E'\n'
          || 'We kept this enquiry for you while your free enquiries were used up. '
          || 'Your page is on Plus now, so every enquiry comes straight to you.';
  elsif e.free_slot then
    lim := (public.free_enquiry_rule() ->> 'limit')::int;
    select count(*) into used from public.enquiries x
     where x.venue_id = e.venue_id and x.free_slot
       and (x.created_at, x.id) <= (e.created_at, e.id);
    pitch := 'About your listing' || E'\n'
          || 'With Nomadwise Plus, you can receive an unlimited number of '
          || 'enquiries straight to your inbox, along with other benefits for '
          || 'your page. This was free enquiry ' || used || ' of ' || lim
          || ' included with your free plan.' || E'\n\n'
          || 'See everything Plus includes: https://nomadmaps.io/?owner&billing';
  elsif v.listing_tier = 'verified' then
    pitch := 'Your Plus page does not have an enquiry address yet. Add one in '
          || 'your Owner account and future enquiries will reach you directly:' || E'\n'
          || 'https://nomadmaps.io/?owner';
  elsif coalesce(trim(v.listing_owner_email), '') = '' then
    pitch := 'About your listing' || E'\n'
          || v.name || ' is listed on Nomadwise free of charge, based on publicly '
          || 'available information. You can claim the page at no cost to keep your '
          || 'details up to date and add your own photos, prices and opening hours:' || E'\n'
          || 'https://nomadmaps.io/?claim='
          || coalesce(v.webflow_slug, replace(v.name, ' ', '%20'));
  else
    pitch := 'About your listing' || E'\n'
          || 'With Nomadwise Plus, you can receive an unlimited number of '
          || 'enquiries straight to your inbox, along with other benefits for '
          || 'your page.' || E'\n\n'
          || 'See everything Plus includes: https://nomadmaps.io/?owner&billing';
  end if;

  return jsonb_build_object(
    'subject', 'New enquiry for ' || v.name || ' from Nomadwise',
    'body',
      'Hi ' || v.name || ' team,' || E'\n\n'
      || 'You have a new enquiry from a remote worker who found '
      || case when page is not null then 'your page' else 'you' end
      || ' on Nomadwise' || coalesce(': ' || page, '.') || E'\n\n'
      || 'Name: ' || e.name || E'\n'
      || 'Email: ' || e.email || E'\n'
      || coalesce('Phone: ' || nullif(e.phone, '') || E'\n', '')
      || case e.want when 'day_pass' then 'Interested in: a day pass' || E'\n'
                     when 'desk_month' then 'Interested in: a desk for a month or longer' || E'\n'
                     when 'event' then 'Interested in: a meeting or event' || E'\n'
                     else '' end
      || coalesce('Dates: ' || nullif(e.dates, '') || E'\n', '')
      || coalesce('People: ' || e.people::text || E'\n', '')
      || 'Sent: ' || to_char(e.created_at at time zone 'utc', 'FMDD Mon YYYY') || E'\n\n'
      || 'Their message:' || E'\n'
      || coalesce(nullif(btrim(e.message), ''), '(No message)') || E'\n\n'
      || 'To reply, simply answer this email. Your reply goes directly to '
      || coalesce(first, 'them') || '.' || E'\n\n'
      || pitch || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;

-- start_claim: from migration 217, wording only.
create or replace function public.start_claim(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c_id  uuid;
  v     public.venues%rowtype;
  v_id  uuid;
  em    text := lower(trim(coalesce(p->>'owner_email', '')));
  nm    text := trim(coalesce(p->>'owner_name', ''));
  label text;
  site  text := nullif(left(trim(coalesce(p->>'space_website', '')), 300), '');
  insta text := nullif(left(trim(coalesce(p->>'space_instagram', '')), 300), '');
  free  boolean := lower(coalesce(p->>'plan', '')) = 'free';
begin
  if position('@' in em) < 2 or char_length(em) > 200 then
    raise exception 'A working email address is needed.';
  end if;
  if char_length(nm) < 2 then
    raise exception 'Your name is needed.';
  end if;

  if (select count(*) from public.listing_claims
       where owner_email = em and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Too many attempts from this address; try again later.';
  end if;
  if (select count(*) from public.listing_claims
       where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'We are busy right now; please try again in a few minutes.';
  end if;

  if site is not null and site !~* '^https?://' then
    site := 'https://' || site;
  end if;
  if insta is not null and insta !~* '^https?://' then
    insta := 'https://www.instagram.com/' || ltrim(insta, '@') || '/';
  end if;

  v_id := nullif(trim(coalesce(p->>'venue_id', '')), '')::uuid;
  if v_id is not null then
    select * into v from public.venues where id = v_id;
    if not found then
      raise exception 'That listing could not be found.';
    end if;
    if v.listing_tier = 'verified' then
      raise exception 'This listing is already on Plus. Email hello@nomadwise.io and we will sort it out.';
    end if;
    if free and v.listing_owner_email is not null
       and lower(v.listing_owner_email) = em then
      raise exception 'This listing is already yours. Email hello@nomadwise.io for anything you need changed.';
    end if;
  elsif char_length(trim(coalesce(p->>'space_name', ''))) < 2 then
    raise exception 'The name of your space is needed.';
  end if;

  insert into public.listing_claims (
    venue_id, is_new_space, owner_name, owner_email, owner_phone, owner_role,
    enquiry_email, space_name, space_type, space_address, space_city,
    space_country, space_website, space_instagram, space_place_id,
    space_lat, space_lng, note, plan, status)
  values (
    v_id,
    v_id is null,
    left(nm, 120),
    em,
    nullif(left(trim(coalesce(p->>'owner_phone', '')), 60), ''),
    nullif(left(trim(coalesce(p->>'owner_role', '')), 80), ''),
    nullif(lower(left(trim(coalesce(p->>'enquiry_email', '')), 200)), ''),
    coalesce(nullif(left(trim(coalesce(p->>'space_name', '')), 200), ''), v.name),
    case when lower(coalesce(p->>'space_type', '')) = 'cafe' then 'cafe' else 'coworking' end,
    nullif(left(trim(coalesce(p->>'space_address', '')), 300), ''),
    nullif(left(trim(coalesce(p->>'space_city', '')), 120), ''),
    nullif(left(trim(coalesce(p->>'space_country', '')), 120), ''),
    site,
    insta,
    nullif(trim(coalesce(p->>'space_place_id', '')), ''),
    (nullif(trim(coalesce(p->>'space_lat', '')), ''))::double precision,
    (nullif(trim(coalesce(p->>'space_lng', '')), ''))::double precision,
    nullif(left(trim(coalesce(p->>'note', '')), 2000), ''),
    case when free then 'free' else 'verified' end,
    case when free then 'free_pending' else 'started' end)
  returning id into c_id;

  label := coalesce(nullif(trim(coalesce(p->>'space_name', '')), ''), v.name, nm);
  if free then
    perform public.notify_phone(
      label || ' claimed for free, approve?',
      nm || ' claims ' || label ||
        case when v_id is null then ' (new space)' else '' end ||
        ' for free. Approve or reject it in Owners.',
      'eyes');
  else
    perform public.notify_phone(
      'Someone is claiming ' || label,
      'On the payment page for Plus' ||
        case when v_id is null then ' (new space)' else '' end || '.',
      'eyes');
  end if;

  return jsonb_build_object('claim_id', c_id, 'venue_id', v_id,
                            'plan', case when free then 'free' else 'verified' end);
end $$;

-- site_chat_instructions: from migration 217, wording only.
create or replace function public.site_chat_instructions()
returns text language sql immutable as $$
  select concat_ws(E'\n',
'You are the chat assistant on nomadwise.io, writing for Nomadwise in a chat box on the website.',
'',
'About Nomadwise:',
'- Nomadwise.io is a guide to work-friendly cafes and coworking spaces for remote workers and digital nomads: around 1,000 places in many countries. Each page shows what matters for working there: WiFi speed, plug sockets, opening hours, quiet space, calls and more. Using the site is free. It also has travel guides (eSIMs, VPNs and insurance for nomads).',
'- Nomadwise does not take payments for desks, day passes or meeting rooms, and cannot see availability, but the team can help. You can share prices, opening hours and other facts that are in the page information below. When someone wants to book, check availability, get a day pass or a membership, asks something the page information does not answer, or wants to get in touch with a place, do not send them to a page, a website or a button. Instead ask them to leave a message here about what they are looking for, or their question, with the best way to reach them, and say we will be in touch. For example: "Leave us a message here about what you are looking for, or your question, and the best way to reach you, and we will be in touch." That needs a person. This is for people looking for a place to work; someone who runs or looks after a space gets the claim link instead (see below).',
'- Anyone can suggest a correction or a tag with "Something need updating?" or "Add a tag" on a place''s page, or simply tell you here.',
'',
'For people who run a cafe or coworking space:',
'- If someone runs or looks after a cafe or coworking space, give them the claim link for their page (not the message above). Being listed on Nomadwise is free. They can claim their page for free: on the place''s page press "Claim this listing for free", or go to https://nomadmaps.io/?claim (and search for their space). Use the exact claim link given below when you have one.',
'- After claiming they have their own Owner account, where they update opening hours and contact details and add their own photos, description and prices. A person checks each change before it goes live.',
'- There is an optional paid plan, Nomadwise Plus: the Verified by Nomadwise badge, top positioning on their region''s page, unlimited enquiries, their own events and offers on the page, their Instagram and WhatsApp on the page, and no adverts. Every page, free or Plus, has the Send an enquiry button, and a free page includes 2 enquiries. The price is in the Owner account; never quote a price yourself.',
'- If their space is not on Nomadwise yet, ask for its name, the city, its website or Instagram, and the best way to reach them, and say Jonathan from the team will look at adding it. That needs a person.',
'',
'How to write:',
'- Sound like a friendly, knowledgeable person from an established company: warm, natural and brief. Usually one to three short sentences, never more than about 90 words. Plain text only: no markdown, no headings, no bold. A short list of up to three places is fine, one per line.',
'- Answer in the language the visitor writes in. Otherwise British English.',
'- Never use the long dash character. Never promise a time ("within 24 hours", "today"); "as soon as possible" is fine. Do not oversell.',
'- Only use facts given here or on the page information below. Never invent a place, a price, opening hours or a feature. If you do not know, say so and offer that Jonathan from the team can find out and get back to them.',
'- When you suggest other places, give each name with its full page link. Never give a link to the page the visitor is already on.',
'- Ask at most one question in a reply.',
'- You are an automated assistant for Nomadwise, not a person. Do not pretend to be one. If someone asks, say so plainly, and that Jonathan, a cofounder, reads every chat and can reply himself. Never name the AI model or the company that made it.',
'- A person from the team is needed when: they ask for a person; they want to book or check availability, or want to contact a place; they report something wrong on a page; it is a complaint, a partnership, press or business question; their space is not listed yet; or you cannot help. Then say Jonathan will pick it up, and if you do not have a way to reach them yet, ask for the best way to reach them: an email address, or a WhatsApp or phone number, whichever they prefer. Accept either; do not insist on email. If they give a phone number without a country code (for example it starts with 0) and you cannot tell the country from the chat, ask which country the number is from.',
'',
'Answer with this JSON and nothing else:',
'{"reply": "your message to the visitor", "who": "owner" if they run a space, "visitor" if they are looking for places, or "unknown", "needs_person": true or false, "email": "their email address if they gave one in this chat, else empty", "phone": "their WhatsApp or phone number if they gave one in this chat, written in international format starting with + and the country code when you know the country (for example +44 7591 915767), else exactly as they wrote it; empty if none"}');
$$;

-- site_chat_venue_line: from migration 217, wording only.
create or replace function public.site_chat_venue_line(v public.venues, p_area text default null)
returns text language plpgsql stable set search_path = public as $$
declare
  g     jsonb := coalesce(v.g_details, '{}'::jsonb);
  hours text;
  facts text;
  rating numeric;
begin
  select string_agg(h, '; ') into hours
    from jsonb_array_elements_text(
           case when jsonb_typeof(coalesce(g -> 'regularOpeningHours', g -> 'currentOpeningHours') -> 'weekdayDescriptions') = 'array'
                then coalesce(g -> 'regularOpeningHours', g -> 'currentOpeningHours') -> 'weekdayDescriptions'
                else '[]'::jsonb end) h;
  facts := array_to_string(array_remove(array[
    case when v.power_outlets then 'plug sockets' end,
    case when v.aircon then 'aircon' end,
    case when v.comfortable_seating then 'comfortable seating' end,
    case when v.office_chairs then 'office chairs' end,
    case when v.quiet_space then 'quiet space' end,
    case when v.good_for_calls then 'good for calls' end,
    case when v.call_room then 'call room or booth' end,
    case when v.monitor then 'monitors' end,
    case when v.access_24h then '24-hour access' end,
    case when v.cozy then 'cozy' end,
    case when v.serves_food then 'serves food' end,
    case when v.laptops_allowed is false then 'laptops not always welcome' end
  ], null), ', ');
  rating := coalesce(nullif(g ->> 'rating', '')::numeric, v.google_rating_snapshot);
  return concat_ws(' | ',
    v.name || ' (' || public.space_kind(v.type) || ')',
    nullif(concat_ws(', ', nullif(btrim(coalesce(p_area, v.neighbourhood, '')), ''), nullif(btrim(coalesce(v.city, '')), '')), ''),
    case when coalesce(v.wifi_speed_mbps, 0) > 0 then 'WiFi about ' || round(v.wifi_speed_mbps) || ' Mbps' end,
    case when rating is not null then 'Google rating ' || rating end,
    nullif(facts, ''),
    case when hours is not null then 'hours: ' || hours end,
    case when v.listing_tier = 'verified' then 'Plus listing (Verified by Nomadwise badge, top positioning)' end,
    case when v.webflow_slug is not null then 'page: https://www.nomadwise.io/coworking/' || v.webflow_slug end);
exception when others then
  return v.name;
end $$;

update public.outreach_templates
   set body = replace(body, 'choose Free or Nomadwise Plus', 'choose Free or Plus')
 where position('choose Free or Nomadwise Plus' in body) > 0;

notify pgrst, 'reload schema';
