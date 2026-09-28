-- ============================================================
-- Migration 84: the "page is live" email waits for the real thing.
-- (Applied automatically by the build; nothing to paste.)
--
-- The sync marks a page 'published_hidden' when it creates the DRAFT
-- in Webflow, before a founder has published it; the email went out
-- at that moment with a link that did not work yet (Kopi Club, 27
-- Sep). Now it goes only when the page is 'released': published and
-- in the sitemap, which the sync confirms after the founder's publish.
-- ============================================================

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
  -- One live email per page, ever.
  if exists (select 1 from public.owner_emails e
              where e.kind = 'page_live' and e.ref = new.id::text
                and e.status = 'sent') then
    return new;
  end if;

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
