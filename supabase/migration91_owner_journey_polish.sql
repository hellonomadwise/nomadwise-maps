-- ============================================================
-- Migration 91: what the first full paid test (28 Sep) turned up.
-- (Applied automatically by the build; nothing to paste.)
--
--  1. Emails say what the owner did, in their words: "You've claimed
--     your coworking space" (or cafe), no time promises ("usually
--     within a day"), no booking button (bookings are discontinued; the
--     page has a Send an enquiry button), and they only describe what
--     is really on the page.
--  2. The inbox preview shows the first sentence, not
--     "nomadwiseFOR SPACES"; "nomadwise.io" written in a sentence no
--     longer turns into a link to the homepage.
--  3. A cancelled Verified plan tells the owner (and the phone):
--     plan_ended(), called by the Stripe sync.
--  4. Phone pings: "Someone is claiming X", the amount really paid and
--     the code used (not a fixed EUR 99), and "Owners" (the tab's name)
--     instead of "Paid listings".
--  5. Owner account before approval: owner_pending_claims() lets a
--     signed-in owner see their claim and where it stands, instead of
--     "No space on this account yet".
--  6. claim_paid() could be called by anyone who knew a claim's id,
--     marking it paid without paying. Only the Stripe sync (service
--     key) may call it now.
-- ============================================================

-- 6 ----------------------------------------------------------------
revoke all on function public.claim_paid(uuid, jsonb) from public, anon, authenticated;

-- Stripe orders remember the discount, for the card and the ping.
alter table public.stripe_orders
  add column if not exists promo_code text,
  add column if not exists amount_discount numeric;

-- "coworking space", "cafe" or "space", for sentences.
create or replace function public.space_kind(p_type text)
returns text language sql immutable as $$
  select case lower(coalesce(p_type, ''))
           when 'cafe' then 'cafe'
           when 'coworking' then 'coworking space'
           when 'coliving' then 'coliving space'
           else 'space' end
$$;

-- 2 ----------------------------------------------------------------
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
  pre    text := '';
begin
  if coalesce(p_cta_label, '') <> '' and coalesce(p_cta_url, '') <> '' then
    button := '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 26px;">'
           || '<tr><td style="background:#E0442E;border-radius:10px;">'
           || '<a href="' || replace(p_cta_url, '"', '') || '" style="display:inline-block;padding:13px 22px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">'
           || replace(replace(p_cta_label, '<', '&lt;'), '>', '&gt;') || '</a></td></tr></table>';
  end if;

  paras := regexp_split_to_array(coalesce(p_text, ''), E'\n\n+');
  n := coalesce(array_length(paras, 1), 0);

  -- The inbox preview: the first real sentence, not the greeting and
  -- not the wordmark. Hidden in the email itself.
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
    esc := replace(replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
    -- "nomadwise.io" in a sentence: mail apps would link it to the
    -- homepage. An invisible break stops that; web addresses (with
    -- https:// or www.) are left alone and linked below.
    esc := regexp_replace(esc, '(^|[^/.@[:alnum:]])nomadwise\.io\M', '\1nomadwise&#8203;.io', 'gi');
    esc := regexp_replace(esc, '(https?://[^[:space:]<]+[^[:space:]<.,;:!?)])',
                          '<a href="\1" style="color:#E0442E;text-decoration:underline;">\1</a>', 'g');
    esc := replace(esc, E'\n', '<br>');
    if i = n and n > 1 then
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
      || '<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;font-size:1px;line-height:1px;color:#F7F8F9;">'
      || pre || repeat('&#847; &zwnj;&nbsp;', 40) || '</div>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F7F8F9;">'
      || '<tr><td align="center" style="padding:28px 16px;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">'
      || '<tr><td style="padding:0 6px 14px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;">'
      || '<span style="font-size:22px;font-weight:800;color:#E0442E;letter-spacing:-0.3px;">nomadwise</span> '
      || '<span style="font-size:12px;font-weight:700;color:#5C6773;letter-spacing:1.2px;margin-left:4px;">FOR SPACES</span>'
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

-- 1 ---------------------------------------------------------------- claims
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
  city    text;
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
  kind_of := public.space_kind(coalesce(
               (select type from public.venues where id = new.venue_id), new.space_type));
  city  := coalesce(nullif((select city from public.venues where id = new.venue_id), ''),
                    nullif(new.space_city, ''), 'your city');
  first := coalesce(nullif(split_part(trim(coalesce(new.owner_name, '')), ' ', 1), ''), 'there');
  url   := public.owner_page_url(new.venue_id);

  -- Free claim just made.
  if tg_op = 'INSERT' and new.status = 'free_pending' then
    kind := 'claim_received';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'You''ve claimed ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks, you''ve claimed your ' || kind_of || ', ' || space || ', on Nomadwise. '
         || 'Before we hand the page over we confirm it really is yours, and we email '
         || 'you as soon as that is done.' || E'\n\n'
         || case when new.is_new_space
                 then 'Your ' || kind_of || ' is not on our map yet, so it also joins our '
                      || 'publishing queue; we email you the link when the page is live.'
                 else 'Your page: ' || coalesce(url, 'we send the link once it is live.') end
         || E'\n\n'
         || 'Your Owner account is ready to sign in to now. Once we have confirmed you, '
         || 'you can correct the facts and add your own photos, description, prices and '
         || 'opening hours there.'
         || owner_line || sig;

  -- Payment landed, claim waiting for us.
  elsif tg_op = 'UPDATE' and old.status = 'started' and new.status = 'awaiting_approval' then
    kind := 'payment_received';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'Payment received for ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks, you''ve claimed your ' || kind_of || ', ' || space || ', and your '
         || 'payment has arrived; Stripe sends the receipt separately. Next we confirm '
         || space || ' is yours, then Verified goes on and we email you.' || E'\n\n'
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
    subj := space || ' is Verified on Nomadwise';
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Done: ' || space || ' is now Verified, and your page moves above the free '
         || 'listings in ' || city || '. Enquiries sent from your page come straight to '
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
         || 'Done: we have confirmed ' || space || ' is yours, and you are on record as '
         || 'its owner.' || E'\n\n'
         || case when url is not null then 'Your page: ' || url || E'\n\n'
                 else 'The page is in our publishing queue; we check every new page before '
                      || 'it goes live and will email you the link.' || E'\n\n' end
         || 'From your Owner account you can correct the facts and add your own '
         || 'photos, description, prices and opening hours. We read each change before '
         || 'it goes on the page.' || E'\n\n'
         || 'When you want more, Verified is 99 EUR a year: the Verified badge, a place '
         || 'above the free listings in ' || city || ', enquiries straight to your inbox, '
         || 'and your own event or offer on the page. The Go Verified button is in your '
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
  return new;
end $$;

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
  if new.website_status <> 'released' then return new; end if;
  if coalesce(old.website_status, '') = 'released' then return new; end if;
  if new.webflow_slug is null or new.webflow_slug = '' then return new; end if;
  if exists (select 1 from public.owner_emails e
              where e.kind = 'page_live' and e.ref = new.id::text
                and e.status = 'sent') then
    return new;
  end if;

  first := coalesce(nullif(split_part(trim(coalesce(new.listing_owner_name, '')), ' ', 1), ''), 'there');
  url := 'https://www.nomadwise.io/coworking/' || new.webflow_slug;
  body := 'Hi ' || first || ',' || E'\n\n'
       || new.name || ' is live on Nomadwise: ' || url || E'\n\n'
       || case when new.listing_tier = 'verified'
               then 'It is Verified and sits above the free listings in '
                    || coalesce(nullif(new.city, ''), 'your city') || '. Enquiries sent '
                    || 'from the page go to '
                    || coalesce(nullif(new.listing_enquiry_email, ''), new.listing_owner_email) || '.'
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

-- ---------------------------------------------------- started, not finished
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
          || 'Verified, 99 EUR a year: the badge, a place above the free listings in '
          || 'your city, enquiries straight to your inbox, and your own event or offer '
          || 'on the page.' || E'\n\n'
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

-- 3 ---------------------------------------------------- plan ended
-- Called by the Stripe sync when a Verified subscription ends. Tells
-- the owner in plain words, and the phone.
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
    'Verified ended: ' || v.name,
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
       || 'Your Verified plan for ' || v.name || ' has ended, so the page is back to a '
       || 'free listing. It stays on Nomadwise, and you still manage it from your Owner '
       || 'account.' || E'\n\n'
       || case when url is not null then 'Your page: ' || url || E'\n\n' else '' end
       || 'If that is not what you meant, you can go Verified again from your Owner '
       || 'account at any time, or simply reply to this email.'
       || E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
  perform public.send_owner_email(v.listing_owner_email,
                                  'Your Verified plan for ' || v.name || ' has ended',
                                  body, 'plan_ended', v.id::text,
                                  'Open my Owner account', 'https://nomadmaps.io/owner');
exception when others then
  null;
end $$;
revoke all on function public.plan_ended(uuid, text) from public, anon, authenticated;

-- ------------------------------------------------------------ enquiries
-- The page's button is "Send an enquiry" now; the email says so.
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

  subj := 'Enquiry for ' || v.name || ' from Nomadwise';
  body := 'New enquiry for ' || v.name || ', sent from your page on Nomadwise.' || E'\n\n'
       || 'From:     ' || e.name || ' <' || e.email || '>' || E'\n'
       || coalesce('Phone:    ' || nullif(e.phone, '') || E'\n', '')
       || 'About:    ' || what || E'\n'
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

-- 5 ---------------------------------------------------- owner account
-- The signed-in owner's claims that are not approved yet, so the
-- Owner account can show where each one stands.
create or replace function public.owner_pending_claims()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em  text := public.owner_email();
  out jsonb;
begin
  if em is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'claim_id', c.id,
      'venue_id', c.venue_id,
      'name', coalesce(v.name, c.space_name, 'Your space'),
      'type', coalesce(v.type, c.space_type),
      'city', coalesce(v.city, c.space_city),
      'neighbourhood', v.neighbourhood,
      'plan', c.plan,
      'status', c.status,
      'paid', c.status = 'awaiting_approval' or c.paid_at is not null,
      'is_new_space', c.is_new_space,
      'created_at', c.created_at,
      'page_url', public.owner_page_url(c.venue_id),
      'photo', (select value from jsonb_each_text(coalesce(v.google_photo_urls, '{}'::jsonb)) limit 1)
    ) order by c.created_at desc), '[]'::jsonb)
    into out
    from public.listing_claims c
    left join public.venues v on v.id = c.venue_id
   where lower(c.owner_email) = em
     and (c.status in ('awaiting_approval', 'free_pending')
          or (c.status = 'started' and c.created_at > now() - interval '30 days'))
     -- not for a space this person already manages
     and not exists (select 1 from public.venues o
                      where o.id = c.venue_id and lower(o.listing_owner_email) = em);
  return out;
end $$;
grant execute on function public.owner_pending_claims() to authenticated;

-- 4 ---------------------------------------------------- phone pings
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
      raise exception 'This listing is already Verified. Email hello@nomadwise.io and we will sort it out.';
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
      'On the payment page for Verified' ||
        case when v_id is null then ' (new space)' else '' end || '.',
      'eyes');
  end if;

  return jsonb_build_object('claim_id', c_id, 'venue_id', v_id,
                            'plan', case when free then 'free' else 'verified' end);
end $$;
grant execute on function public.start_claim(jsonb) to anon, authenticated;

create or replace function public.claim_paid(p_claim uuid, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      public.listing_claims%rowtype;
  v_id   uuid;
  v_name text;
  fresh  boolean := false;
  again  boolean := false;
  held   boolean := false;
  paid   text;
begin
  select * into c from public.listing_claims where id = p_claim;
  if not found then
    return null;
  end if;

  again := c.status in ('paid', 'awaiting_approval', 'rejected');
  v_id := c.venue_id;

  if v_id is null and c.space_place_id is not null then
    select id into v_id from public.venues where google_place_id = c.space_place_id;
  end if;

  if v_id is null then
    insert into public.venues (
      name, type, city, country, website, instagram, google_place_id, lat, lng,
      status, website_status)
    values (
      coalesce(nullif(c.space_name, ''), 'Unnamed space'),
      coalesce(nullif(c.space_type, ''), 'coworking'),
      coalesce(nullif(c.space_city, ''), 'Unknown'),
      nullif(c.space_country, ''),
      nullif(c.space_website, ''),
      nullif(c.space_instagram, ''),
      c.space_place_id,
      c.space_lat,
      c.space_lng,
      'verified',
      'queued')
    returning id into v_id;
    fresh := true;
  end if;

  if again then
    select name into v_name from public.venues where id = v_id;
    return jsonb_build_object('venue_id', v_id, 'name', v_name,
                              'new_space', false,
                              'held', c.status = 'awaiting_approval');
  end if;

  update public.listing_claims
     set order_json = coalesce(p_order, '{}'::jsonb),
         paid_at = coalesce(paid_at, now()),
         venue_id = v_id
   where id = p_claim;

  -- What was really paid, and the code if one was used.
  paid := coalesce(nullif(p_order->>'currency', ''), 'EUR') || ' '
       || coalesce(rtrim(to_char(nullif(p_order->>'amount', '')::numeric, 'FM999990.##'), '.'), '?')
       || case when coalesce(p_order->>'promo_code', '') <> ''
               then ' (code ' || (p_order->>'promo_code') || ')'
               when coalesce(nullif(p_order->>'amount_discount', '')::numeric, 0) > 0
               then ' (with a discount)'
               else '' end;

  if fresh then
    update public.listing_claims set status = 'paid' where id = p_claim;
    v_name := public.apply_claim(p_claim);
    perform public.notify_phone(
      'PAID, new space in the queue',
      coalesce(v_name, c.space_name, 'A space') || ' paid ' || paid || '. ' ||
        'It is in the publishing queue: review it and approve it.',
      'moneybag');
  else
    held := true;
    update public.listing_claims set status = 'awaiting_approval' where id = p_claim;
    select name into v_name from public.venues where id = v_id;
    perform public.notify_phone(
      'PAID, approve the claim',
      coalesce(v_name, c.space_name, 'A space') || ' paid ' || paid || ' through the claim form. ' ||
        'Nothing changes on the page until you approve it in Owners.',
      'moneybag');
  end if;

  return jsonb_build_object('venue_id', v_id, 'name', v_name,
                            'new_space', fresh, 'held', held);
end $$;
revoke all on function public.claim_paid(uuid, jsonb) from public, anon, authenticated;

-- The claim form knows the space's type, so the thank-you page can
-- say "You've claimed your cafe".
drop function if exists public.claim_search(text);
create function public.claim_search(p_query text)
returns table (
  id uuid, name text, city text, neighbourhood text, country text,
  webflow_slug text, on_site boolean, already_verified boolean, type text)
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.city, v.neighbourhood, v.country, v.webflow_slug,
         v.webflow_cms_id is not null,
         v.listing_tier = 'verified',
         v.type
    from public.venues v
   where char_length(trim(p_query)) >= 2
     and (v.webflow_slug = trim(p_query)
          or v.name ilike '%' || trim(p_query) || '%')
     and coalesce(v.website_status, '') <> 'retired'
     and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
   order by (v.webflow_slug = trim(p_query)) desc,
            (v.webflow_cms_id is not null) desc, v.name
   limit 25;
$$;
grant execute on function public.claim_search(text) to anon, authenticated;
