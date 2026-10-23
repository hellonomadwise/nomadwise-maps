-- ============================================================
-- Migration 214: softer wording in the two free-enquiry emails.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 23 Oct, on the line added to a free enquiry (migration
-- 212): no "From the next one, enquiries are kept for you until you
-- move to Plus" (it does not need saying), and say that Nomadwise Plus
-- means an unlimited number of enquiries, as the main point, with a
-- link to see the rest. The line now reads:
--   With Nomadwise Plus, you can receive an unlimited number of
--   enquiries straight to your inbox, along with other benefits for
--   your page. This was free enquiry 1 of 2 included with your free
--   plan.
--   See everything Plus includes: https://nomadmaps.io/?owner&billing
-- Also the owner's email when an enquiry arrives after the free ones
-- (Jonathan: not "we are keeping this one for you"). It now reads:
--   Your free plan includes 2 enquiries, which you have now received.
--   With Nomadwise Plus, you can receive an unlimited number of
--   enquiries straight to your inbox, including this one, as well as
--   the Verified by Nomadwise badge and top positioning on your
--   region's page.
-- Everything else in both emails is as in migration 212. The rule is
-- still switched off, so nothing is sent with it yet.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.enquiry_space_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  page  text;
  pitch text;
  first text;
  used  int;
  lim   int;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;

  page := case when v.webflow_slug is not null
               then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  first := nullif(nullif(split_part(trim(e.name), ' ', 1), ''), 'Someone');

  if e.held_at is not null then
    -- Kept while the free enquiries were used up, sent now on Plus.
    pitch := 'About this enquiry' || E'\n'
          || 'We kept this enquiry for you while your free enquiries were used up. '
          || 'Your page is on Plus now, so every enquiry comes straight to you.';
  elsif e.free_slot then
    lim := (public.free_enquiry_rule() ->> 'limit')::int;
    select count(*) into used from public.enquiries x
     where x.venue_id = e.venue_id and x.free_slot
       and (x.created_at, x.id) <= (e.created_at, e.id);
    pitch := 'About your listing' || E'\n'
          || 'With Nomadwise Plus, you can receive an unlimited number of '
          || 'enquiries straight to your inbox, along with other benefits for '
          || 'your page. This was free enquiry ' || used || ' of ' || lim
          || ' included with your free plan.' || E'\n\n'
          || 'See everything Plus includes: https://nomadmaps.io/?owner&billing';
  elsif v.listing_tier = 'verified' then
    pitch := 'Your Verified page does not have an enquiry address yet. Add one in '
          || 'your Owner account and future enquiries will reach you directly:' || E'\n'
          || 'https://nomadmaps.io/?owner';
  elsif coalesce(trim(v.listing_owner_email), '') = '' then
    pitch := 'About your listing' || E'\n'
          || v.name || ' is listed on Nomadwise free of charge, based on publicly '
          || 'available information. You can claim the page at no cost to keep your '
          || 'details up to date and add your own photos, prices and opening hours:' || E'\n'
          || 'https://nomadmaps.io/?claim='
          || coalesce(v.webflow_slug, replace(v.name, ' ', '%20'));
  else
    pitch := 'About your listing' || E'\n'
          || 'Enquiries for your page currently come to us first, and we pass them on '
          || 'to you. With a Verified listing they reach your inbox directly, and your '
          || 'page is shown with the Verified badge above other listings in '
          || coalesce(nullif(v.city, ''), 'your city') || ':' || E'\n'
          || 'https://nomadmaps.io/?owner&billing';
  end if;

  return jsonb_build_object(
    'subject', 'New enquiry for ' || v.name || ' from Nomadwise',
    'body',
      'Hi ' || v.name || ' team,' || E'\n\n'
      || 'You have a new enquiry from a remote worker who found '
      || case when page is not null then 'your page' else 'you' end
      || ' on Nomadwise' || coalesce(': ' || page, '.') || E'\n\n'
      || 'Name: ' || e.name || E'\n'
      || 'Email: ' || e.email || E'\n'
      || coalesce('Phone: ' || nullif(e.phone, '') || E'\n', '')
      || case e.want when 'day_pass' then 'Interested in: a day pass' || E'\n'
                     when 'desk_month' then 'Interested in: a desk for a month or longer' || E'\n'
                     when 'event' then 'Interested in: a meeting or event' || E'\n'
                     else '' end
      || coalesce('Dates: ' || nullif(e.dates, '') || E'\n', '')
      || coalesce('People: ' || e.people::text || E'\n', '')
      || 'Sent: ' || to_char(e.created_at at time zone 'utc', 'FMDD Mon YYYY') || E'\n\n'
      || 'Their message:' || E'\n'
      || coalesce(nullif(btrim(e.message), ''), '(No message)') || E'\n\n'
      || 'To reply, simply answer this email. Your reply goes directly to '
      || coalesce(first, 'them') || '.' || E'\n\n'
      || pitch || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;
revoke all on function public.enquiry_space_email(uuid) from public, anon, authenticated;

create or replace function public.enquiry_held_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  first text;
  lim   int := (public.free_enquiry_rule() ->> 'limit')::int;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;
  first := nullif(split_part(btrim(coalesce(v.listing_owner_name, '')), ' ', 1), '');
  return jsonb_build_object(
    'to', public.enquiry_address(v.id),
    'subject', 'A new enquiry for ' || v.name || ' is waiting for you',
    'body',
      'Hi ' || coalesce(first, v.name || ' team') || ',' || E'\n\n'
      || 'A remote worker has just sent ' || v.name || ' an enquiry through your '
      || 'page on Nomadwise.' || E'\n\n'
      || 'Your free plan includes ' || lim || ' enquiries, which you have now '
      || 'received. With Nomadwise Plus, you can receive an unlimited number of '
      || 'enquiries straight to your inbox, including this one, as well as the '
      || 'Verified by Nomadwise badge and top positioning on your region''s page.'
      || E'\n\n'
      || 'If you have any questions, simply reply to this email.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;
revoke all on function public.enquiry_held_email(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
