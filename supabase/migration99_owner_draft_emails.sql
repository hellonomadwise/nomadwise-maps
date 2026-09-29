-- ============================================================
-- Migration 99: kinder "sent back" email for owners' changes.
-- (Applied automatically by the build; nothing to paste.)
--
-- When a founder sends an owner's changes back (Owner changes, Send
-- back), the owner is emailed with the note and a button to their
-- Owner account. The old wording ("we sent your changes back rather
-- than putting them on the page") read as a rejection. It now reads
-- as a quick suggestion, with the draft kept and one tap to finish.
-- A failure is logged in Emails to owners instead of vanishing.
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
begin
  if tg_op <> 'UPDATE' or old.status = new.status then return new; end if;
  select v.name into space from public.venues v where v.id = new.venue_id;
  space := coalesce(space, 'your space');
  url := public.owner_page_url(new.venue_id);

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
         || 'https://nomadmaps.io/owner'
         || sig;
  elsif new.status = 'declined' then
    kind := 'changes_back';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'A quick note about your changes to ' || space;
    body := 'Hi,' || E'\n\n'
         || 'Thank you for updating ' || space || '. Before we put your changes on '
         || 'the page, we have a small suggestion.'
         || case when coalesce(new.review_note, '') <> ''
                 then E'\n\n' || new.review_note else '' end
         || E'\n\n'
         || 'Your changes are saved in your Owner account. Sign in, adjust them and '
         || 'submit again, and we will put them straight on: '
         || 'https://nomadmaps.io/owner' || E'\n\n'
         || 'Any questions, just reply to this email.'
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
