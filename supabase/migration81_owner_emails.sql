-- ============================================================
-- Migration 81: the emails an owner gets, at every step.
-- (Applied automatically by the build; nothing to paste.)
--
-- Until now an owner heard from us once, on the screen after the
-- claim form, and then nothing: not that they were approved, not
-- that their page went live, not that their edit is on the page.
-- These emails close every one of those silences. They are sent
-- through Postmark (Vault secret `postmark_server_token`); until
-- that token exists each email is logged as "skipped" in
-- owner_emails and nothing else happens. The booking-request email
-- from migration 66 is re-created below to use Postmark as well.
--
-- hello@nomadwise.io is copied on every one, so the founders see
-- what the owner sees.
--
-- Triggers rather than edits to the claim functions, so the flow
-- that works today is untouched:
--   listing_claims  insert free_pending            -> claim received
--                   started -> awaiting_approval    -> payment received
--                   -> paid / -> free               -> approved
--                   -> rejected                     -> rejected
--   owner_drafts    -> applied / -> declined        -> changes live / sent back
--   venues          website_status becomes live     -> page is live
--   cron, 09:00 UTC daily: claims started a day ago and not finished
--                                                   -> one nudge
-- ============================================================

create table if not exists public.owner_emails (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null,
  to_email    text not null,
  subject     text not null,
  ref         text,                 -- claim / draft / venue id
  status      text not null default 'sent' check (status in ('sent','skipped','failed')),
  error       text,
  provider_req text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_owner_emails_created on public.owner_emails(created_at desc);
alter table public.owner_emails enable row level security;
drop policy if exists "owner_emails admin" on public.owner_emails;
create policy "owner_emails admin" on public.owner_emails
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Send one plain-text email to an owner. Never raises.
create or replace function public.send_owner_email(
  p_to text, p_subject text, p_text text, p_kind text, p_ref text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  token text;
  req   bigint;
  dest  text := lower(trim(coalesce(p_to, '')));
begin
  if dest = '' or position('@' in dest) < 2 then return; end if;

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
      'TextBody', p_text,
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

-- The page's address, when it has one.
create or replace function public.owner_page_url(p_venue uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when v.webflow_slug is not null and v.webflow_slug <> ''
              then 'https://www.nomadwise.io/coworking/' || v.webflow_slug
              else null end
    from public.venues v where v.id = p_venue
$$;

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

  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text);
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
begin
  if tg_op <> 'UPDATE' or old.status = new.status then return new; end if;
  select name into space from public.venues where id = new.venue_id;
  space := coalesce(space, 'your space');
  url := public.owner_page_url(new.venue_id);

  if new.status = 'applied' then
    kind := 'changes_live';
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

  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text);
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
                                  body, 'page_live', new.id::text);
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
                                    body, 'finish_claim', c.id::text);
    update public.listing_claims set nudged_at = now() where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  perform cron.unschedule('nudge-started-claims');
exception when others then null;
end $$;
select cron.schedule('nudge-started-claims', '0 9 * * *',
  'select public.nudge_started_claims()');
