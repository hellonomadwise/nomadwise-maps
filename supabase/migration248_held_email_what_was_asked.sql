-- ============================================================
-- Migration 248: the "held for Premium" email shows what was asked.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 4 Nov 2026 (from the open list: "change the held for
-- Premium email so it shows the space what the person asked for").
--
-- When a free page has used its free enquiries, the next ones are held
-- and the owner gets "A new enquiry for X is waiting for you". Until now
-- that email said nothing about the enquiry. It now shows what was
-- asked, taken from the enquiry's own lines (Asking about, People, Day
-- or Starting, Time), never who sent it or their message: those stay
-- for Premium, which sends every held enquiry straight away.
-- An enquiry without those lines (the site's older pop-up) says a
-- message is waiting instead.
-- ============================================================

create or replace function public.enquiry_held_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e      public.enquiries%rowtype;
  v      public.venues%rowtype;
  first  text;
  lim    int := (public.free_enquiry_rule() ->> 'limit')::int;
  asked  text;
  extra  boolean;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;
  first := nullif(split_part(btrim(coalesce(v.listing_owner_name, '')), ' ', 1), '');

  -- Only the structured lines the enquiry pop-up writes: no name, email,
  -- phone or free text.
  select string_agg(btrim(l), E'\n' order by n)
    into asked
    from regexp_split_to_table(coalesce(e.message, ''), E'\n') with ordinality as t(l, n)
   where btrim(l) ~* '^(asking about|people|day|starting|time):\s*\S';
  extra := btrim(regexp_replace(coalesce(e.message, ''),
             E'(^|\n)\\s*(asking about|people|day|starting|time):[^\n]*', '', 'gi'))
           !~* '^\s*(\(sent from the price list on the page\.\))?\s*$';

  return jsonb_build_object(
    'to', public.enquiry_address(v.id),
    'subject', 'A new enquiry for ' || v.name || ' is waiting for you',
    'body',
      'Hi ' || coalesce(first, v.name || ' team') || ',' || E'\n\n'
      || 'A remote worker has just sent ' || v.name || ' an enquiry through your '
      || 'page on Nomadwise.' || E'\n\n'
      || case when asked is not null
              then 'What they asked:' || E'\n' || asked || E'\n\n'
                   || 'Their name' || case when extra then ', email and message' else ' and email' end
                   || ' come with Nomadwise Premium.' || E'\n\n'
              else 'Their message, name and email come with Nomadwise Premium.' || E'\n\n' end
      || 'Your free plan includes ' || lim || ' enquiries, which you have now '
      || 'received. With Nomadwise Premium, you can receive an unlimited number of '
      || 'enquiries straight to your inbox, including this one, as well as the '
      || 'Verified by Nomadwise badge and top positioning on your region''s page.'
      || E'\n\n'
      || 'If you have any questions, simply reply to this email.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;
