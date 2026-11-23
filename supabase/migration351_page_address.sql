-- A listing page that shows products also gets the space's street
-- address in words, with a "Get directions" link.
--
-- Jonathan, 23 Nov 2026 (benchmark, batch 3): the best listing pages
-- put the address under the name; ours showed only the area. The short
-- address we already hold from the space's Google listing is used as
-- it is. Directions open in Google Maps at the space's own pin.
--
-- page_prices gains four keys. The rest of the function is left as it
-- is, so they are spliced into the live definition. Safe to run twice.
do $mig$
declare
  d      text := pg_get_functiondef('public.page_prices(text)'::regprocedure);
  marker text := E'    ''closed_days'', shut,\n';
  added  text := E'    ''closed_days'', shut,\n'
    || E'    ''address'', (select nullif(btrim(x.g_details ->> ''shortFormattedAddress''), '''')\n'
    || E'                  from public.venues x where x.id = v.id),\n'
    || E'    ''lat'', (select x.lat from public.venues x where x.id = v.id),\n'
    || E'    ''lng'', (select x.lng from public.venues x where x.id = v.id),\n'
    || E'    ''place'', (select nullif(btrim(x.google_place_id), '''') from public.venues x where x.id = v.id),\n';
begin
  if position('''address''' in d) > 0 then
    return;
  end if;
  if position(marker in d) = 0 then
    raise exception 'page_prices: the place to add the address was not found';
  end if;
  execute replace(d, marker, added);
end
$mig$;
