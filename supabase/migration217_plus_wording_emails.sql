-- ============================================================
-- Migration 217: the paid plan is called Nomadwise Plus in the owner
-- emails, the Outreach templates and the chat on nomadwise.io.
-- (Applied automatically by the build; nothing to paste.)
--
-- CR-30. The claim page and the Owner account already say Plus. This
-- does the same for the words owners read in emails, using the wording
-- Leonie checked on the CR-30 card (24 Oct). "Verified" stays only as
-- the name of the badge, "Verified by Nomadwise".
--   * claim emails (payment received, Plus approved, free approved)
--   * the reminder for a claim stopped halfway
--   * Plus plan ended, and "your page is live" for a Plus page
--   * an enquiry passed on by hand (Plus page with no address; free page)
--   * the red email button "See Nomadwise Plus"
--   * the claim page message "This listing is already on Plus."
--   * the site chat's description of the plans
--   * the founders' phone notices say Plus (internal only)
--   * Outreach templates: the same phrases are swapped wherever they
--     appear. A template reworded by hand that still says Verified is
--     left alone and listed in the build log (NOTICE lines), so it can
--     be changed in Outreach.
-- Only wording changes: who gets which email, and when, is unchanged.
-- Each function below is the latest version, word for word, apart
-- from the swapped lines.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

-- claim_emails: from migration 166, wording only.
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
         || 'are with the team at ' || space || ', then Nomadwise Plus goes on and we email you.' || E'\n\n'
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
         || 'Done: ' || space || ' is now on Nomadwise Plus. Your page has the Verified '
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

-- nudge_started_claims: from migration 115, wording only.
create or replace function public.nudge_started_claims()
returns integer language plpgsql security definer set search_path = public as $$
declare
  c       record;
  n       integer := 0;
  space   text;
  kind_of text;
  first   text;
  link    text;
  body    text;
  sig     text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
begin
  for c in
    select * from public.listing_claims
     where status = 'started'
       and nudged_at is null
       and coalesce(owner_email, '') <> ''
       and created_at between now() - interval '3 days' and now() - interval '20 hours'
       and not exists (select 1 from public.owner_emails e
                        where e.to_email = lower(listing_claims.owner_email)
                          and e.kind = 'finish_claim')
  loop
    space := coalesce(nullif(c.space_name, ''),
                      (select name from public.venues where id = c.venue_id),
                      'your space');
    kind_of := public.space_kind(coalesce(
                 (select type from public.venues where id = c.venue_id), c.space_type));
    first := coalesce(nullif(split_part(trim(coalesce(c.owner_name, '')), ' ', 1), ''), 'there');
    link  := 'https://nomadmaps.io/?claim=' || replace(space, ' ', '%20');
    body  := 'Hi ' || first || ',' || E'\n\n'
          || 'You started claiming your ' || kind_of || ', ' || space || ', on Nomadwise '
          || 'yesterday and stopped before the last step, so nothing has changed yet.' || E'\n\n'
          || 'Two ways to finish, both take a minute: ' || link || E'\n\n'
          || 'Free: you become the owner of the page and can correct it and add your '
          || 'photos, prices and hours.' || E'\n'
          || 'Nomadwise Plus, '
          || public.verified_price_words(coalesce((select country from public.venues where id = c.venue_id), c.space_country))
          || ': the Verified by Nomadwise badge, top positioning on your region''s '
          || 'page, unlimited enquiries straight to your inbox, and your own events and '
          || 'offers on your page.' || E'\n\n'
          || 'If something on the form did not work, reply and tell us; we read every '
          || 'answer.'
          || sig;
    perform public.send_owner_email(c.owner_email,
                                    'Finish claiming your ' || kind_of || ', ' || space,
                                    body, 'finish_claim', c.id::text,
                                    'Finish my claim', link);
    update public.listing_claims set nudged_at = now() where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- plan_ended: from migration 91, wording only.
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
       || 'Your Nomadwise Plus plan for ' || v.name || ' has ended, so the page is back on '
       || 'the free plan. It stays on Nomadwise, and you still manage it from your Owner '
       || 'account.' || E'\n\n'
       || case when url is not null then 'Your page: ' || url || E'\n\n' else '' end
       || 'If that is not what you meant, you can get Nomadwise Plus again from your Owner '
       || 'account at any time, or simply reply to this email.'
       || E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
  perform public.send_owner_email(v.listing_owner_email,
                                  'Your Nomadwise Plus plan for ' || v.name || ' has ended',
                                  body, 'plan_ended', v.id::text,
                                  'Open my Owner account', 'https://nomadmaps.io/owner');
exception when others then
  null;
end $$;

-- page_live_email: from migration 136, wording only.
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
               then 'It is on Nomadwise Plus, with the Verified by Nomadwise badge and top '
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

-- enquiry_space_email: from migration 214, wording only.
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
    pitch := 'Your Nomadwise Plus page does not have an enquiry address yet. Add one in '
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

-- email_html: from migration 196, wording only.
create or replace function public.email_html(
  p_text text, p_cta_label text default null, p_cta_url text default null,
  p_for_spaces boolean default true)
returns text language plpgsql immutable as $$
declare
  paras  text[];
  p      text;
  esc    text;
  body   text := '';
  n      int;
  i      int := 0;
  button text := '';
  pre    text := '';
  font   text := 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;';
  head   text;
  rest   text;
  url    text;
  lbl    text;
  who    text;
  role   text;
begin
  if coalesce(p_cta_label, '') <> '' and coalesce(p_cta_url, '') <> '' then
    button := '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 26px;">'
           || '<tr><td style="background:#E0442E;border-radius:10px;">'
           || '<a href="' || replace(p_cta_url, '"', '') || '" style="display:inline-block;padding:13px 22px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">'
           || replace(replace(p_cta_label, '<', '&lt;'), '>', '&gt;') || '</a></td></tr></table>';
  end if;

  paras := regexp_split_to_array(coalesce(p_text, ''), E'\n\n+');
  n := coalesce(array_length(paras, 1), 0);

  -- The inbox preview: the first real sentence, not the greeting.
  if n >= 2 and paras[1] ~* '^(hi|hello)\M' then
    pre := paras[2];
  elsif n >= 1 then
    pre := paras[1];
  end if;
  pre := regexp_replace(pre, 'https?://[^[:space:]]+', '', 'g');
  pre := left(regexp_replace(pre, '[[:space:]]+', ' ', 'g'), 140);
  pre := replace(replace(replace(pre, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

  foreach p in array paras loop
    i := i + 1;
    p := btrim(replace(p, E'\r', ''), E' \n\t');

    -- The sign-off: "Kind regards," then the name in bold and the role.
    if p ~ '^Kind regards,[ \t]*\n[ \t]*Jonathan( Heavens)?[ \t]*\n[ \t]*(Co-founder, )?Nomadwise[ \t]*$' then
      who  := case when p ~ 'Jonathan Heavens' then 'Jonathan Heavens' else 'Jonathan' end;
      role := case when p ~ 'Co-founder, Nomadwise' then 'Co-founder, ' else '' end;
      body := body || case when i = n then button else '' end
           || '<p style="margin:8px 0 10px;font-size:16px;line-height:1.6;color:#142032;">Kind regards,</p>'
           || '<p style="margin:0;font-size:16px;line-height:1.4;font-weight:700;color:#142032;">' || who || '</p>'
           || '<p style="margin:2px 0 0;font-size:14px;line-height:1.5;color:#5C6773;">' || role
           || '<a href="https://www.nomadwise.io" style="color:#E0442E;font-weight:700;text-decoration:none;">Nomadwise</a></p>';
      if i = n then button := ''; end if;
      continue;
    end if;

    esc := replace(replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
    -- "nomadwise.io" in a sentence: an invisible break stops mail apps
    -- linking it; full web addresses are linked below.
    esc := regexp_replace(esc, '(^|[^/.@[:alnum:]])nomadwise\.io\M', '\1nomadwise&#8203;.io', 'gi');

    -- "About your listing" (any short "About ..." first line): what we
    -- offer the space, set apart in a light panel; a link on its own
    -- last line becomes a button.
    if p ~ '^About [A-Za-z'' ]{3,40}\n' then
      head := split_part(esc, E'\n', 1);
      rest := substr(esc, length(head) + 2);
      url := substring(rest from '\n(https?://[^[:space:]<]+)$');
      lbl := null;
      if url is not null then
        lbl := case when url ~ '\?claim=' then 'Claim your page'
                    when url ~ '\?owner&amp;billing' then 'See Nomadwise Plus'
                    when url ~ '\?owner' then 'Open your Owner account'
                    else null end;
      end if;
      if lbl is not null then
        rest := left(rest, length(rest) - length(url) - 1);
      end if;
      rest := regexp_replace(rest, '(https?://[^[:space:]<]+[^[:space:]<.,;:!?)])',
                             '<a href="\1" style="color:#E0442E;text-decoration:underline;">\1</a>', 'g');
      rest := replace(rest, E'\n', '<br>');
      body := body
           || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 24px;">'
           || '<tr><td style="background:#F4F6F8;border-radius:12px;padding:20px 22px;">'
           || '<p style="margin:0 0 6px;font-size:15px;line-height:1.4;font-weight:700;color:#142032;">' || head || '</p>'
           || '<p style="margin:0;font-size:15px;line-height:1.6;color:#3E4C59;">' || rest || '</p>'
           || case when lbl is not null then
                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:14px 0 0;">'
                || '<tr><td style="background:#E0442E;border-radius:9px;">'
                || '<a href="' || url || '" style="display:inline-block;padding:11px 18px;font-size:14px;font-weight:700;color:#ffffff;text-decoration:none;">'
                || lbl || '</a></td></tr></table>'
              else '' end
           || '</td></tr></table>';
      continue;
    end if;

    esc := regexp_replace(esc, '(https?://[^[:space:]<]+[^[:space:]<.,;:!?)])',
                          '<a href="\1" style="color:#E0442E;text-decoration:underline;">\1</a>', 'g');
    esc := replace(esc, E'\n', '<br>');
    if i = n and n > 1 then
      body := body || button
           || '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">' || esc || '</p>';
      button := '';
    else
      body := body || '<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">' || esc || '</p>';
    end if;
  end loop;
  body := body || button;

  return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      || '<title>Nomadwise</title></head>'
      || '<body style="margin:0;padding:0;background:#F7F8F9;">'
      || '<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;font-size:1px;line-height:1px;color:#F7F8F9;">'
      || pre || repeat('&#847; &zwnj;&nbsp;', 40) || '</div>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F7F8F9;">'
      || '<tr><td align="center" style="padding:28px 16px;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">'
      || '<tr><td style="padding:0 6px 14px;' || font || '">'
      || '<span style="font-size:22px;font-weight:800;color:#E0442E;letter-spacing:-0.3px;">nomadwise</span>'
      || case when p_for_spaces
              then ' <span style="font-size:12px;font-weight:700;color:#5C6773;letter-spacing:1.2px;margin-left:4px;">FOR SPACES</span>'
              else '' end
      || '</td></tr>'
      || '<tr><td style="background:#ffffff;border:1px solid rgba(20,32,50,0.10);border-radius:16px;padding:30px 30px 26px;' || font || '">'
      || body
      || '</td></tr>'
      || '<tr><td style="padding:16px 6px 0;' || font || 'font-size:12px;line-height:1.6;color:#96A0AC;">'
      || 'Nomadwise, work from anywhere. Reply to this email and a person answers. '
      || '<a href="https://www.nomadwise.io" style="color:#96A0AC;">nomadwise.io</a>'
      || case when p_for_spaces
              then ' &middot; <a href="https://nomadmaps.io/owner" style="color:#96A0AC;">Owner account</a>'
              else '' end
      || '</td></tr></table></td></tr></table></body></html>';
end $$;

-- start_claim: from migration 91, wording only.
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
      raise exception 'This listing is already on Nomadwise Plus. Email hello@nomadwise.io and we will sort it out.';
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

-- site_chat_instructions: from migration 208, wording only.
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
'- There is an optional paid plan, Nomadwise Plus: the Verified by Nomadwise badge, top positioning on their region''s page, unlimited enquiries, their own events and offers on the page, their Instagram and WhatsApp on the page, and no adverts. Every page, free or Nomadwise Plus, has the Send an enquiry button, and a free page includes 2 enquiries. The price is in the Owner account; never quote a price yourself.',
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

-- site_chat_venue_line: from migration 190, wording only.
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
    case when v.listing_tier = 'verified' then 'Nomadwise Plus listing (Verified by Nomadwise badge, top positioning)' end,
    case when v.webflow_slug is not null then 'page: https://www.nomadwise.io/coworking/' || v.webflow_slug end);
exception when others then
  return v.name;
end $$;

-- Outreach templates: swap the plan wording, longest phrases first.
do $tpl$
declare
  pairs text[][] := array[
    array['And Verified, which adds the Verified badge, a place above every free listing in your city, and a Send an enquiry button that emails you directly',
          'And Nomadwise Plus, which adds the Verified by Nomadwise badge, top positioning on your region''s page, and unlimited enquiries straight to your inbox'],
    array['Verified adds the Verified badge, a place above every free listing in your city, and a Send an enquiry button that emails you directly',
          'Nomadwise Plus adds the Verified by Nomadwise badge, top positioning on your region''s page, and unlimited enquiries straight to your inbox'],
    array['Verified adds the Verified badge, a place above every free listing in your area and enquiries sent straight to your inbox',
          'Nomadwise Plus adds the Verified by Nomadwise badge, top positioning on your region''s page and unlimited enquiries straight to your inbox'],
    array['Verified adds the Verified badge, a place above every free listing in your area and enquiries straight to your inbox',
          'Nomadwise Plus adds the Verified by Nomadwise badge, top positioning on your region''s page and unlimited enquiries straight to your inbox'],
    array['Verified adds the Verified badge, a place above every free listing in your city and enquiries straight to your inbox',
          'Nomadwise Plus adds the Verified by Nomadwise badge, top positioning on your region''s page and unlimited enquiries straight to your inbox'],
    array['If you would like the Verified badge, a place above every free listing in your city and enquiries straight to your inbox, that is',
          'If you would like Nomadwise Plus, with the Verified by Nomadwise badge, top positioning on your region''s page and unlimited enquiries straight to your inbox, that is'],
    array['and Verified for {price_words} if you want the badge, the placement above free listings and enquiries straight to your inbox',
          'and Nomadwise Plus for {price_words} if you want the Verified by Nomadwise badge, top positioning on your region''s page and unlimited enquiries straight to your inbox'],
    array['an optional Verified listing', 'an optional Nomadwise Plus plan'],
    array['choose Free or Verified', 'choose Free or Nomadwise Plus']
  ];
  i int;
  r record;
begin
  for i in 1 .. array_length(pairs, 1) loop
    update public.outreach_templates
       set body = replace(body, pairs[i][1], pairs[i][2])
     where position(pairs[i][1] in body) > 0;
    update public.outreach_templates
       set subject = replace(subject, pairs[i][1], pairs[i][2])
     where position(pairs[i][1] in coalesce(subject, '')) > 0;
  end loop;
  for r in
    select key, name from public.outreach_templates
     where replace(coalesce(subject, '') || ' ' || coalesce(body, ''),
                   'Verified by Nomadwise', '') like '%Verified%'
  loop
    raise notice 'Outreach template still says Verified, change it in Outreach: % (%)', r.name, r.key;
  end loop;
end
$tpl$;

notify pgrst, 'reload schema';
