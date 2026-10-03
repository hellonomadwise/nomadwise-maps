-- ============================================================
-- Migration 120: the claim emails open with the fact, not "Thanks".
-- (Applied automatically by the build; nothing to paste.)
--
-- "Thanks, you've claimed your cafe, X, on Nomadwise" opened on a
-- thank-you that nobody asked for (Jonathan, 3 Oct 2026). The two
-- emails sent when a claim comes in (free, and paid) now open with
-- "You've claimed your ...". claim_emails() is otherwise as in
-- migration 115.
-- ============================================================

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
         || 'you can correct the facts and add your own photos, description, prices and '
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
         || 'are with the team at ' || space || ', then Verified goes on and we email you.' || E'\n\n'
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
         || 'listings in ' || v_city || '. Enquiries sent from your page come straight to '
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
         || 'From your Owner account you can correct the facts and add your own '
         || 'photos, description, prices and opening hours. We read each change before '
         || 'it goes on the page.' || E'\n\n'
         || 'When you want more, Verified is '
         || public.verified_price_words(coalesce((select country from public.venues where id = new.venue_id), new.space_country))
         || ': the Verified badge, a place '
         || 'above the free listings in ' || v_city || ', enquiries straight to your inbox, '
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
  -- Never silent again: a failure here shows in Emails to owners.
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, error)
    values ('claim_email', coalesce(lower(new.owner_email), '?'),
            'Claim email for ' || coalesce(new.space_name, 'a space'),
            new.id::text, 'failed', left(sqlerrm, 300));
  exception when others then null; end;
  return new;
end $$;
