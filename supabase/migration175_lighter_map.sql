-- 175: the map loads a light copy of the spaces.
--
-- Jonathan, 8 Oct 2026: Supabase says the project went over the free
-- plan's data allowance (6.65 GB sent out of 5 GB this cycle; grace
-- period until 7 Nov 2026).
--
-- Measured the same day: every time the map opened, it asked for every
-- column of every space, about 15 MB (3.7 MB as sent, compressed).
-- Most of it was never shown on the map: Google's full answer for each
-- place (g_details, 5 MB), the links to all of its photos (3.2 MB), the
-- photo-checking notes of the nightly job (2.8 MB), food photo lists,
-- page proposals. About 75 map opens a day (people, the founders'
-- control centre, crawlers) made the 6.65 GB.
--
-- map_venues() gives the map what it shows: every column it reads, with
-- Google's answer cut to the parts the app uses (name, rating, address,
-- type, opening hours, position, country and town) and one photo, the
-- first one that is neither hidden nor food, with its link. A space's
-- card and page ask for that one space in full when opened (about
-- 15 KB), so their photos are as before. The answer is also a single
-- value, so it is not cut at 1,000 rows as the plain read was (22
-- spaces were missing from the map).
--
-- It runs as the person asking, so what they may see is unchanged.
-- Safe to apply twice.

create or replace function public.map_venue_row(v public.venues)
returns jsonb language plpgsql immutable as $$
declare
  g      jsonb := v.g_details;
  cur    jsonb;
  reg    jsonb;
  names  text[];
  nofood text[];
  keep   text;
  slim   jsonb;
  urls   jsonb;
begin
  -- every column, without the ones the map never reads, and no empties
  slim := jsonb_strip_nulls(to_jsonb(v)
            - 'g_details' - 'google_photo_urls' - 'photos_checked'
            - 'food_photos' - 'hidden_photos' - 'website_photo_candidates'
            - 'website_prepared');

  if jsonb_typeof(g) = 'object' then
    -- the first photo that is not hidden, and not food unless all are
    names := array(select p ->> 'name'
                     from jsonb_array_elements(case when jsonb_typeof(g -> 'photos') = 'array'
                                                    then g -> 'photos' else '[]'::jsonb end)
                          with ordinality as x(p, o)
                    where p ->> 'name' is not null
                      and not ((p ->> 'name') = any (coalesce(v.hidden_photos, '{}'::text[])))
                    order by o);
    nofood := array(select n from unnest(names) with ordinality as y(n, o)
                     where not (n = any (coalesce(v.food_photos, '{}'::text[])))
                     order by o);
    keep := coalesce(nofood[1], names[1]);

    cur := case when jsonb_typeof(g -> 'currentOpeningHours') = 'object' then g -> 'currentOpeningHours' end;
    reg := case when jsonb_typeof(g -> 'regularOpeningHours') = 'object' then g -> 'regularOpeningHours' end;

    slim := slim || jsonb_build_object('g_details', jsonb_strip_nulls(jsonb_build_object(
      'displayName', g -> 'displayName',
      'rating', g -> 'rating',
      'userRatingCount', g -> 'userRatingCount',
      'location', g -> 'location',
      'shortFormattedAddress', g -> 'shortFormattedAddress',
      'formattedAddress', case when g -> 'shortFormattedAddress' is null then g -> 'formattedAddress' end,
      'primaryType', g -> 'primaryType',
      'types', g -> 'types',
      'websiteUri', g -> 'websiteUri',
      'internationalPhoneNumber', g -> 'internationalPhoneNumber',
      'nationalPhoneNumber', case when g -> 'internationalPhoneNumber' is null then g -> 'nationalPhoneNumber' end,
      -- the country and the town only
      'addressComponents', (select jsonb_agg(jsonb_build_object(
                                     'longText', a -> 'longText', 'shortText', a -> 'shortText',
                                     'types', a -> 'types'))
                              from jsonb_array_elements(case when jsonb_typeof(g -> 'addressComponents') = 'array'
                                                             then g -> 'addressComponents' else '[]'::jsonb end) a
                             where (a -> 'types') ?| array['country', 'locality', 'postal_town',
                                                           'administrative_area_level_2']),
      -- one set of hours: the regular week (no dates), open now as Google last said
      'regularOpeningHours', case when coalesce(reg, cur) is not null then jsonb_strip_nulls(jsonb_build_object(
          'openNow', coalesce(cur -> 'openNow', reg -> 'openNow'),
          'periods', coalesce(reg -> 'periods', cur -> 'periods'),
          'weekdayDescriptions', coalesce(reg -> 'weekdayDescriptions', cur -> 'weekdayDescriptions'))) end,
      'photos', case when keep is not null then jsonb_build_array(jsonb_build_object('name', keep)) end)));

    if keep is not null and jsonb_typeof(v.google_photo_urls) = 'object'
       and v.google_photo_urls ? keep then
      urls := jsonb_build_object(keep, v.google_photo_urls -> keep);
      slim := slim || jsonb_build_object('google_photo_urls', urls);
    end if;
  end if;

  -- the card and the page ask for the rest when opened
  return slim || jsonb_build_object('slim', true);
end $$;

create or replace function public.map_venues()
returns jsonb language sql stable set search_path = public as $$
  -- As the map's own read: a place Google reports closed for good
  -- leaves the map, unless a founder has said it is still open.
  select coalesce(jsonb_agg(public.map_venue_row(v)), '[]'::jsonb)
    from public.venues v
   where v.business_status is null
      or v.business_status <> 'CLOSED_PERMANENTLY'
      or v.closed_dismissed_at is not null;
$$;
grant execute on function public.map_venues() to anon, authenticated;
grant execute on function public.map_venue_row(public.venues) to anon, authenticated;
