-- ============================================================
-- Migration 100: owner emails open the Owner account ready to sign in.
-- (Applied automatically by the build; nothing to paste.)
--
-- The "changes on the page" and "a quick note about your changes"
-- emails now link to nomadmaps.io/owner?email=<their email>, so the
-- sign-in box is already filled in, and say in one line how signing in
-- works (press "Email me a sign-in link", no password; "Continue with
-- Google" for Gmail addresses), and that they then stay signed in and
-- can bookmark nomadmaps.io/owner. The "note" email also links to
-- their page as it is today.
-- ============================================================

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
  em        text := lower(coalesce(new.owner_email, ''));
  -- Their Owner account with their email already filled in, so signing
  -- in is one tap: they press "Email me a sign-in link" and open it.
  acct      text := 'https://nomadmaps.io/owner?email='
                    || replace(replace(lower(coalesce(new.owner_email, '')), '+', '%2B'), '@', '%40');
  how       text;
begin
  if tg_op <> 'UPDATE' or old.status = new.status then return new; end if;
  select v.name into space from public.venues v where v.id = new.venue_id;
  space := coalesce(space, 'your space');
  url := public.owner_page_url(new.venue_id);
  how := E'\n\n' || 'To sign in, open the link above and press "Email me a sign-in link": '
      || 'we send a link to ' || em || ', no password needed.'
      || case when em like '%@gmail.com' or em like '%@googlemail.com'
              then ' As it is a Gmail address, "Continue with Google" works too.' else '' end
      || ' After that you stay signed in on that device: bookmark '
      || 'nomadmaps.io/owner to come straight back.';

  if new.status = 'applied' then
    kind := 'changes_live';
    cta_label := case when url is not null then 'See my page' else 'Open my Owner account' end;
    cta_url := coalesce(url, 'https://nomadmaps.io/owner');
    subj := 'Your changes to ' || space || ' are on the page';
    body := 'Hi,' || E'\n\n'
         || 'Thank you for updating ' || space || '. Your changes are going onto '
         || 'the page now; give it a few minutes to show.'
         || case when url is not null then E'\n\n' || 'Your page: ' || url else '' end
         || E'\n\n' || 'Anything else to change, it is all in your Owner account: '
         || acct || how
         || sig;
  elsif new.status = 'declined' then
    kind := 'changes_back';
    cta_label := 'Open my Owner account'; cta_url := acct;
    subj := 'A quick note about your changes to ' || space;
    body := 'Hi,' || E'\n\n'
         || 'Thank you for updating ' || space || '. Before we put your changes on '
         || 'the page, we have a small suggestion.'
         || case when coalesce(new.review_note, '') <> ''
                 then E'\n\n' || new.review_note else '' end
         || E'\n\n'
         || 'Your changes are saved in your Owner account. Sign in, adjust them and '
         || 'submit again, and we will put them straight on: '
         || acct || how
         || case when url is not null then E'\n\n' || 'Your page as it is today: ' || url else '' end
         || E'\n\n' || 'Any questions, just reply to this email.'
         || sig;
  else
    return new;
  end if;

  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);
  return new;
exception when others then
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, error)
    values ('owner_draft_email', coalesce(lower(new.owner_email), '?'),
            'Owner changes email', new.id::text, 'failed', left(sqlerrm, 300));
  exception when others then null; end;
  return new;
end $$;
