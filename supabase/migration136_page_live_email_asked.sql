-- ============================================================
-- Migration 136: "Your page is live", for a space the owner asked for.
-- (Applied automatically by the build; nothing to paste.)
--
-- The email said "It is a free listing, built from public
-- information" to every owner. Jonathan, 5 Oct 2026 (PLACE Coworking
-- Phuket): when the manager asked us to add the space, they gave the
-- first details themselves and we added to them while checking the
-- claim, so "public information" is the wrong story. For a space that
-- came from such a request (a claim marked as a space not listed yet)
-- the line now reads: "built from the details you sent us and what we
-- could confirm ourselves ... It is in your hands now." A page that
-- was already listed and then claimed keeps the old line. Nothing
-- else in the email changes (same as migration 91).
-- ============================================================

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
               then 'It is Verified and sits above the free listings in '
                    || coalesce(nullif(new.city, ''), 'your city') || '. Enquiries sent '
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
