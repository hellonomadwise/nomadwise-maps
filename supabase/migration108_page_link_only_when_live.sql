-- ============================================================
-- Migration 108: owner emails only link to a page that is live.
-- (Applied automatically by the build; nothing to paste.)
--
-- A space can have its page address saved (webflow_slug) before the
-- page is actually live: a page being prepared, a draft, or a page
-- taken down. Emails used to link to that address anyway, e.g. "Your
-- page as it is today: ..." in the "quick note about your changes"
-- email, which then opened a page that does not exist.
--
-- owner_page_url now returns the link only when the page is live
-- (website_status 'released', the same test as the "is live on
-- Nomadwise" email). Every email that uses it already leaves the line
-- out, or says the link follows once it is live, when there is none.
--
-- The "your changes are on the page" email also says the right thing
-- when there is no live page yet: the changes are saved and will be
-- on the page when it goes live.
-- ============================================================

create or replace function public.owner_page_url(p_venue uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when v.webflow_slug is not null and v.webflow_slug <> ''
               and v.website_status = 'released'
              then 'https://www.nomadwise.io/coworking/' || v.webflow_slug
              else null end
    from public.venues v where v.id = p_venue
$$;

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
  -- Only set when the page is live (migration 108).
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
    cta_url := coalesce(url, acct);
    subj := case when url is not null
                 then 'Your changes to ' || space || ' are on the page'
                 else 'Your changes to ' || space || ' are approved' end;
    body := 'Hi,' || E'\n\n'
         || 'Thank you for updating ' || space || '. '
         || case when url is not null
                 then 'Your changes are going onto the page now; give it a few minutes to show.'
                      || E'\n\n' || 'Your page: ' || url
                 else 'Your changes are approved and saved. They will be on your page '
                      || 'when it goes live, and we will email you the link then.' end
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
