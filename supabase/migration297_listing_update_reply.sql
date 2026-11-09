-- ============================================================
-- Migration 297: answer a suggestion from a space's owner with a link
-- to their own listing
-- ============================================================
-- Jonathan, 9 Nov 2026, on a suggestion from The Capsule's owner (new
-- opening hours): "I want to be able to easily message them back to
-- say, checkout this link to where you can access your own listing to
-- make changes."
--
-- admin_listing_update_reply(p_id) gets the reply ready: it finds the
-- space's Outreach contact (or makes one), gives it the email and
-- name the suggestion came with when it has none, and returns what
-- the message needs: the contact, the first name, and the link (the
-- claim link when nobody has claimed the space, the owner sign-in
-- when somebody has). The app then sends it through Outreach as
-- usual, so it is in the space's history and counts as outreach.
-- ============================================================

create or replace function public.admin_listing_update_reply(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  u       public.listing_updates%rowtype;
  v       public.venues%rowtype;
  c       public.space_contacts%rowtype;
  em      text;
  claimed boolean;
  link    text;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select * into u from public.listing_updates where id = p_id;
  if not found then
    raise exception 'Suggestion not found.';
  end if;
  em := nullif(lower(trim(coalesce(u.email, ''))), '');
  if em is null then
    raise exception 'They left no email address, so there is nobody to write to.';
  end if;
  if u.venue_id is null then
    raise exception 'This suggestion is not tied to a space on the map.';
  end if;
  select * into v from public.venues where id = u.venue_id;

  -- the space's contact: the one with this email first, else any
  select * into c from public.space_contacts
   where venue_id = u.venue_id and not is_test
   order by (lower(coalesce(email, '')) = em) desc,
            (email is null) desc, created_at
   limit 1;
  if not found then
    insert into public.space_contacts (venue_id, space_name, email, person_name, source, notes)
    values (u.venue_id, coalesce(v.name, u.space_name), em, nullif(trim(u.name), ''),
            'listing', 'Wrote in with a suggestion for their page on '
              || to_char(u.created_at, 'DD Mon YYYY') || '.')
    returning * into c;
  elsif c.email is null or lower(c.email) <> em then
    -- the person who wrote in is who we answer; an address we had
    -- before is kept in the notes
    update public.space_contacts
       set email = em,
           person_name = coalesce(nullif(trim(person_name), ''), nullif(trim(u.name), '')),
           notes = case when c.email is not null
                        then concat_ws(E'\n', notes, 'Email before ' || to_char(now(), 'DD Mon YYYY')
                                       || ': ' || c.email)
                        else notes end
     where id = c.id
    returning * into c;
  end if;

  claimed := exists (select 1 from public.listing_claims l
                      where l.venue_id = u.venue_id and l.status in ('free', 'paid'));
  link := case
    when claimed then 'https://nomadmaps.io/owner'
    when v.webflow_slug is not null then
      'https://nomadwise.io/claim/' || public.claim_link_plain(v.webflow_slug, em, 'email')
    else 'https://nomadmaps.io/?claim=' || public.form_enc(coalesce(u.slug, u.space_name)) || '&from=email'
  end;

  return jsonb_build_object(
    'contact_id', c.id,
    'email', em,
    'first_name', nullif(split_part(trim(coalesce(c.person_name, u.name, '')), ' ', 1), ''),
    'space', coalesce(v.name, u.space_name),
    'claimed', claimed,
    'link', link,
    'unsubscribed', c.unsubscribed_at is not null);
end $$;

revoke all on function public.admin_listing_update_reply(uuid) from public, anon;
grant execute on function public.admin_listing_update_reply(uuid) to authenticated;
