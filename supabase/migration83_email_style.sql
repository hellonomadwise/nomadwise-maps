-- ============================================================
-- Migration 83: owner emails in the house style.
-- (Applied automatically by the build; nothing to paste.)
--
-- The words stay exactly as in migration 81; this dresses them: a
-- white card on the site's grey, the nomadwise wordmark in red, one
-- red button where the email has somewhere to send the reader
-- (Owner account, the page, the claim form), links made clickable,
-- the plain text kept underneath for mail apps that show no HTML.
-- Every email keeps its plain-text twin, so nothing is lost on old
-- phones or in spam filters that dislike HTML-only mail.
-- ============================================================

create or replace function public.owner_email_html(
  p_text text, p_cta_label text default null, p_cta_url text default null)
returns text language plpgsql immutable as $$
declare
  paras  text[];
  p      text;
  esc    text;
  body   text := '';
  n      int;
  i      int := 0;
  button text := '';
begin
  if coalesce(p_cta_label, '') <> '' and coalesce(p_cta_url, '') <> '' then
    button := '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 26px;">'
           || '<tr><td style="background:#E0442E;border-radius:10px;">'
           || '<a href="' || replace(p_cta_url, '"', '') || '" style="display:inline-block;padding:13px 22px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">'
           || replace(replace(p_cta_label, '<', '&lt;'), '>', '&gt;') || '</a></td></tr></table>';
  end if;

  paras := regexp_split_to_array(coalesce(p_text, ''), E'\n\n+');
  n := coalesce(array_length(paras, 1), 0);
  foreach p in array paras loop
    i := i + 1;
    esc := replace(replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
    esc := regexp_replace(esc, '(https?://[^[:space:]<]+[^[:space:]<.,;:!?)])',
                          '<a href="\1" style="color:#E0442E;text-decoration:underline;">\1</a>', 'g');
    esc := replace(esc, E'\n', '<br>');
    if i = n and n > 1 then
      -- the button, then the signature block, quieter
      body := body || button
           || '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">' || esc || '</p>';
    else
      body := body || '<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">' || esc || '</p>';
    end if;
  end loop;
  if n <= 1 then body := body || button; end if;

  return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      || '<title>Nomadwise</title></head>'
      || '<body style="margin:0;padding:0;background:#F7F8F9;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F7F8F9;">'
      || '<tr><td align="center" style="padding:28px 16px;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">'
      || '<tr><td style="padding:0 6px 14px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;">'
      || '<span style="font-size:22px;font-weight:800;color:#E0442E;letter-spacing:-0.3px;">nomadwise</span>'
      || '<span style="font-size:12px;font-weight:700;color:#5C6773;letter-spacing:1.2px;margin-left:8px;">FOR SPACES</span>'
      || '</td></tr>'
      || '<tr><td style="background:#ffffff;border:1px solid rgba(20,32,50,0.10);border-radius:16px;padding:30px 30px 26px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;">'
      || body
      || '</td></tr>'
      || '<tr><td style="padding:16px 6px 0;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.6;color:#96A0AC;">'
      || 'Nomadwise, work from anywhere. Reply to this email and a person answers. '
      || '<a href="https://www.nomadwise.io" style="color:#96A0AC;">nomadwise.io</a> &middot; '
      || '<a href="https://nomadmaps.io/owner" style="color:#96A0AC;">Owner account</a>'
      || '</td></tr></table></td></tr></table></body></html>';
end $$;

-- send_owner_email grows an optional button; older five-argument
-- calls keep working.
drop function if exists public.send_owner_email(text, text, text, text, text);
create or replace function public.send_owner_email(
  p_to text, p_subject text, p_text text, p_kind text, p_ref text default null,
  p_cta_label text default null, p_cta_url text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  token text;
  req   bigint;
  dest  text := lower(trim(coalesce(p_to, '')));
  plain text := p_text;
begin
  if dest = '' or position('@' in dest) < 2 then return; end if;

  -- The button's address also goes into the plain text, so a reader
  -- without HTML still has somewhere to go.
  if coalesce(p_cta_url, '') <> '' and position(p_cta_url in coalesce(p_text, '')) = 0 then
    plain := p_text || E'\n\n' || coalesce(p_cta_label, 'Open') || ': ' || p_cta_url;
  end if;

  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if token is null or token = '' then
    insert into public.owner_emails (kind, to_email, subject, ref, status, error)
    values (p_kind, dest, p_subject, p_ref, 'skipped',
            'No Postmark token in Vault yet (postmark_server_token).');
    return;
  end if;

  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := jsonb_build_object(
      'From', 'Jonathan at Nomadwise <hello@nomadwise.io>',
      'To', dest,
      'Bcc', 'hello@nomadwise.io',
      'ReplyTo', 'hello@nomadwise.io',
      'Subject', p_subject,
      'TextBody', plain,
      'HtmlBody', public.owner_email_html(p_text, p_cta_label, p_cta_url),
      'MessageStream', 'outbound',
      'Tag', p_kind),
    headers := jsonb_build_object(
      'X-Postmark-Server-Token', token,
      'Accept', 'application/json',
      'Content-Type', 'application/json'))
  into req;

  insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req)
  values (p_kind, dest, p_subject, p_ref, 'sent', req::text);
exception when others then
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, error)
    values (p_kind, coalesce(dest, '?'), coalesce(p_subject, ''), p_ref, 'failed', sqlerrm);
  exception when others then null; end;
end $$;

-- Booking requests (migration 66) now go through Postmark too.
create or replace function public.send_enquiry(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  e   public.enquiries%rowtype;
  v   public.venues%rowtype;
  token text;
  dest text;
  what text;
  body text;
  subj text;
  payload jsonb;
  req  bigint;
begin
  select * into e from public.enquiries where id = p_id;
  if not found then return; end if;
  select * into v from public.venues where id = e.venue_id;

  dest := coalesce(nullif(trim(v.listing_enquiry_email), ''), 'hello@nomadwise.io');

  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if token is null or token = '' then
    update public.enquiries set status = 'failed', to_email = dest,
      send_error = 'No Postmark token in Vault yet (postmark_server_token).'
      where id = p_id;
    return;
  end if;

  what := case e.want
            when 'day_pass'   then 'A day pass'
            when 'desk_month' then 'A desk for a month or longer'
            when 'event'      then 'A meeting or event'
            else 'Something else' end;

  subj := 'Booking request for ' || v.name || ' via nomadwise.io';
  body := 'New booking request from nomadwise.io' || E'\n\n'
       || 'Listing:  ' || v.name || E'\n'
       || 'From:     ' || e.name || ' <' || e.email || '>' || E'\n'
       || coalesce('Phone:    ' || nullif(e.phone, '') || E'\n', '')
       || 'Wants:    ' || what || E'\n'
       || coalesce('Dates:    ' || nullif(e.dates, '') || E'\n', '')
       || coalesce('People:   ' || e.people::text || E'\n', '')
       || E'\n' || coalesce(e.message, '') || E'\n\n'
       || 'Reply to this email to answer ' || e.name || ' directly.' || E'\n\n'
       || 'Nomadwise, ' || 'https://www.nomadwise.io/coworking/' || coalesce(v.webflow_slug, '') || E'\n';

  payload := jsonb_build_object(
      'From', 'Nomadwise <hello@nomadwise.io>',
      'To', dest,
      'ReplyTo', e.email,
      'Subject', subj,
      'TextBody', body,
      'HtmlBody', public.owner_email_html(body),
      'MessageStream', 'outbound',
      'Tag', 'enquiry');
  if dest <> 'hello@nomadwise.io' then
    payload := payload || jsonb_build_object('Cc', 'hello@nomadwise.io');
  end if;

  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := payload,
    headers := jsonb_build_object(
      'X-Postmark-Server-Token', token,
      'Accept', 'application/json',
      'Content-Type', 'application/json'))
  into req;

  update public.enquiries
     set status = 'sent', to_email = dest, sent_at = now(),
         resend_id = req::text, send_error = null
   where id = p_id;
exception when others then
  update public.enquiries set status = 'failed', to_email = dest,
    send_error = left(sqlerrm, 300) where id = p_id;
end $$;


-- ---------------------------------------------------------------- claims

create or replace function public.claim_emails()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  space   text;
  first   text;
  url     text;
  subj    text;
  body    text;
  kind    text;
  sig     text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
  owner_line text := E'\n\nYour Owner account: https://nomadmaps.io/owner\n'
                  || 'Sign in with this email address; we send you a link, there is no password.';
  cta_label text;
  cta_url   text;
begin
  if new.owner_email is null or new.owner_email = '' then return new; end if;

  space := coalesce(nullif(new.space_name, ''),
                    (select name from public.venues where id = new.venue_id),
                    'your space');
  first := coalesce(nullif(split_part(trim(coalesce(new.owner_name, '')), ' ', 1), ''), 'there');
  url   := public.owner_page_url(new.venue_id);

  -- 1. Free claim just made.
  if tg_op = 'INSERT' and new.status = 'free_pending' then
    kind := 'claim_received';
    cta_label := 'See how Verified works'; cta_url := 'https://nomadmaps.io/spaces';
    subj := 'We have your claim for ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks for claiming ' || space || ' on nomadwise.io. We read every claim '
         || 'before handing over a page, usually within a day or two, and we will email '
         || 'you the moment it is done.' || E'\n\n'
         || case when new.is_new_space
                 then 'Your space is not on our map yet, so approving the claim also puts '
                      || 'it in our publishing queue. We check every new page before it '
                      || 'goes live and will email you the link.'
                 else 'Your page: ' || coalesce(url, 'we will send the link once it is live.') end
         || E'\n\n'
         || 'Once approved you can add your own photos, prices and opening hours '
         || 'from your Owner account, and Verified (the badge, a place above every '
         || 'free listing, booking requests to your inbox) is there if you want it later.'
         || sig;

  -- 2. Payment landed, claim waiting for us.
  elsif tg_op = 'UPDATE' and old.status = 'started' and new.status = 'awaiting_approval' then
    kind := 'payment_received';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'Payment received for ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks, your payment for ' || space || ' has arrived and your Stripe receipt '
         || 'is on its way separately. One of us now checks the claim, usually within a '
         || 'day, and then the Verified badge, the booking button and your place above '
         || 'the free listings go on.' || E'\n\n'
         || case when new.is_new_space
                 then 'Your space is new to us, so it also joins our publishing queue; we '
                      || 'email you the link the moment the page is live.'
                 else 'Your page: ' || coalesce(url, '(link follows once it is live)') end
         || E'\n\n'
         || 'You can already sign in and prepare your photos, description and prices; '
         || 'they go on the page as soon as we have read them.'
         || owner_line || sig;

  -- 3a. Verified claim approved.
  elsif tg_op = 'UPDATE' and old.status = 'awaiting_approval' and new.status = 'paid' then
    kind := 'approved_verified';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := space || ' is Verified on nomadwise.io';
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Done: ' || space || ' is now Verified. The badge and your place above the '
         || 'free listings in your city are going onto the page now, and booking '
         || 'requests from the page come straight to '
         || coalesce(nullif(new.enquiry_email, ''), new.owner_email) || '.' || E'\n\n'
         || case when url is not null then 'Your page: ' || url || E'\n\n'
                 else 'Your page is in our publishing queue; we email you the link when it is live.' || E'\n\n' end
         || 'Next, make the page yours: sign in to your Owner account, add your photos, '
         || 'your description, prices and opening hours, and if you like, an event or '
         || 'offer that shows on your page where we would otherwise place an advert. '
         || 'We read each change before it goes on, usually the same day.'
         || owner_line || sig;

  -- 3b. Free claim approved.
  elsif tg_op = 'UPDATE' and old.status = 'free_pending' and new.status = 'free' then
    kind := 'approved_free';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'You now manage ' || space || ' on nomadwise.io';
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Done: you are on record as the owner of ' || space || '.' || E'\n\n'
         || case when url is not null then 'Your page: ' || url || E'\n\n'
                 else 'The page is in our publishing queue; we check every new page before '
                      || 'it goes live and will email you the link.' || E'\n\n' end
         || 'From your Owner account you can correct the facts and add your own '
         || 'photos, description, prices and opening hours. We read each change before '
         || 'it goes on the page, usually the same day.' || E'\n\n'
         || 'When you are ready for more, Verified is 99 EUR a year: the Verified badge, '
         || 'a place above every free listing in your city, booking requests straight to '
         || 'your inbox, and your own event or offer on the page. The Go Verified button '
         || 'is in your account.'
         || owner_line || sig;

  -- 4. Rejected.
  elsif tg_op = 'UPDATE' and new.status = 'rejected' and old.status in ('awaiting_approval', 'free_pending') then
    kind := 'rejected';
    subj := 'About your claim for ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks for your claim for ' || space || '. We could not confirm it as coming '
         || 'from the business, so we have not handed the page over.'
         || case when old.status = 'awaiting_approval'
                 then E'\n\n' || 'Your payment is being refunded in full through Stripe; it '
                      || 'shows on your card within a few days.'
                 else '' end
         || E'\n\n'
         || 'If we have this wrong, just reply to this email and tell us who you are at '
         || space || ', and we will sort it out.'
         || sig;
  else
    return new;
  end if;

  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists claim_emails on public.listing_claims;
create trigger claim_emails
  after insert or update of status on public.listing_claims
  for each row execute function public.claim_emails();

-- ---------------------------------------------------------- owner drafts

create or replace function public.owner_draft_emails()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  space text;
  url   text;
  subj  text;
  body  text;
  kind  text;
  sig   text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
  cta_label text;
  cta_url   text;
begin
  if tg_op <> 'UPDATE' or old.status = new.status then return new; end if;
  select name into space from public.venues where id = new.venue_id;
  space := coalesce(space, 'your space');
  url := public.owner_page_url(new.venue_id);

  if new.status = 'applied' then
    kind := 'changes_live';
    cta_label := case when url is not null then 'See my page' else 'Open my Owner account' end;
    cta_url := coalesce(url, 'https://nomadmaps.io/owner');
    subj := 'Your changes to ' || space || ' are on the page';
    body := 'Hi,' || E'\n\n'
         || 'The changes you submitted for ' || space || ' have been read and are going '
         || 'onto the page now; give it a few minutes to show.'
         || case when url is not null then E'\n\n' || 'Your page: ' || url else '' end
         || E'\n\n' || 'Anything else to change, it is all in your Owner account: '
         || 'https://nomadmaps.io/owner'
         || sig;
  elsif new.status = 'declined' then
    kind := 'changes_back';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'We sent your changes to ' || space || ' back';
    body := 'Hi,' || E'\n\n'
         || 'We read the changes you submitted for ' || space || ' and sent them back '
         || 'rather than putting them on the page.'
         || case when coalesce(new.review_note, '') <> ''
                 then E'\n\n' || 'Our note: ' || new.review_note else '' end
         || E'\n\n'
         || 'Nothing is lost: your draft is still in your Owner account, ready to adjust '
         || 'and submit again. https://nomadmaps.io/owner' || E'\n\n'
         || 'If the note does not make sense, reply to this email and we will explain.'
         || sig;
  else
    return new;
  end if;

  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists owner_draft_emails on public.owner_drafts;
create trigger owner_draft_emails
  after update of status on public.owner_drafts
  for each row execute function public.owner_draft_emails();

-- ------------------------------------------------------------ page live

create or replace function public.page_live_email()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  first text;
  url   text;
  body  text;
  sig   text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
begin
  if tg_op <> 'UPDATE' then return new; end if;
  if coalesce(new.listing_owner_email, '') = '' then return new; end if;
  if new.website_status not in ('published_hidden', 'released') then return new; end if;
  if coalesce(old.website_status, '') in ('published_hidden', 'released') then return new; end if;
  if new.webflow_slug is null or new.webflow_slug = '' then return new; end if;

  first := coalesce(nullif(split_part(trim(coalesce(new.listing_owner_name, '')), ' ', 1), ''), 'there');
  url := 'https://www.nomadwise.io/coworking/' || new.webflow_slug;
  body := 'Hi ' || first || ',' || E'\n\n'
       || new.name || ' is live on nomadwise.io: ' || url || E'\n\n'
       || case when new.listing_tier = 'verified'
               then 'The Verified badge is on it and it sits above the free listings in '
                    || coalesce(nullif(new.city, ''), 'your city') || '. Booking requests '
                    || 'from the page go to '
                    || coalesce(nullif(new.listing_enquiry_email, ''), new.listing_owner_email) || '.'
               else 'It is a free listing, built from public information, with a Contact '
                    || 'the space button that sends people to you.' end
       || E'\n\n'
       || 'Have a look, and if anything is wrong or missing, fix it from your Owner '
       || 'account: https://nomadmaps.io/owner. Photos, your own description, prices '
       || 'and opening hours all go on after a quick read from us.'
       || sig;
  perform public.send_owner_email(new.listing_owner_email,
                                  new.name || ' is live on nomadwise.io',
                                  body, 'page_live', new.id::text,
                                  'See my page', url);
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists page_live_email on public.venues;
create trigger page_live_email
  after update of website_status on public.venues
  for each row execute function public.page_live_email();

-- ---------------------------------------------------- started, not finished

alter table public.listing_claims add column if not exists nudged_at timestamptz;

create or replace function public.nudge_started_claims()
returns integer language plpgsql security definer set search_path = public as $$
declare
  c     record;
  n     integer := 0;
  space text;
  first text;
  link  text;
  body  text;
  sig   text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
begin
  for c in
    select * from public.listing_claims
     where status = 'started'
       and nudged_at is null
       and coalesce(owner_email, '') <> ''
       and created_at between now() - interval '3 days' and now() - interval '20 hours'
       -- one nudge per address, ever, however many forms they start
       and not exists (select 1 from public.owner_emails e
                        where e.to_email = lower(listing_claims.owner_email)
                          and e.kind = 'finish_claim')
  loop
    space := coalesce(nullif(c.space_name, ''),
                      (select name from public.venues where id = c.venue_id),
                      'your space');
    first := coalesce(nullif(split_part(trim(coalesce(c.owner_name, '')), ' ', 1), ''), 'there');
    link  := 'https://nomadmaps.io/?claim=' || replace(space, ' ', '%20');
    body  := 'Hi ' || first || ',' || E'\n\n'
          || 'You started claiming ' || space || ' on nomadwise.io yesterday and stopped '
          || 'before the last step, so nothing has changed yet.' || E'\n\n'
          || 'Two ways to finish, both take a minute: ' || link || E'\n\n'
          || 'Free: you become the owner of the page and can correct it and add your '
          || 'photos, prices and hours.' || E'\n'
          || 'Verified, 99 EUR a year: the badge, a place above every free listing in '
          || 'your city, booking requests straight to your inbox, and your own event or '
          || 'offer on the page.' || E'\n\n'
          || 'If something on the form did not work, reply and tell us; we read every '
          || 'answer.'
          || sig;
    perform public.send_owner_email(c.owner_email,
                                    'Your claim for ' || space || ' is one step from done',
                                    body, 'finish_claim', c.id::text,
                                    'Finish my claim', link);
    update public.listing_claims set nudged_at = now() where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $$;


-- The test email from the control centre shows the button as well.
create or replace function public.admin_send_test_email(p_to text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  perform public.send_owner_email(
    p_to,
    'Test email from Nomad Maps',
    'Hi,' || E'\n\n'
    || 'This is a test sent from the control centre at '
    || to_char(now(), 'HH24:MI on DD Mon YYYY') || ' UTC. If you are reading it, '
    || 'owner emails are going out through Postmark, in the house style.' || E'\n\n'
    || 'Jonathan' || E'\n' || 'Nomadwise, https://www.nomadwise.io',
    'test', null, 'Open the Owner account', 'https://nomadmaps.io/owner');
end $$;
