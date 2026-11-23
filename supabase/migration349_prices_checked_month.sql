-- The price list says when its prices were last checked, and a Premium
-- page links to the space's own website from it.
--
-- Jonathan, 23 Nov 2026 (visitor audit, batch 1): nothing on a listing
-- page said how fresh its prices are. The line under "Passes and
-- prices" now reads "Prices set by <space>, checked November 2026."
-- Only the month is shown, and only while the check is under six
-- months old, so the line never shows a stale date ("won't this get
-- stale"). No website is mentioned on a free page, so the Request
-- button stays the way to ask ("ideally we want the user to complete a
-- request form through nomadwise"); a Premium page gets a "Visit
-- website" link ("unless the coworking space has premium perhaps").
--
-- page_prices gains two keys. The rest of the function is left exactly
-- as it is, so they are spliced into the live definition. Safe to run
-- twice.
do $mig$
declare
  d      text := pg_get_functiondef('public.page_prices(text)'::regprocedure);
  marker text := E'    ''closed_days'', shut);';
  added  text := E'    ''closed_days'', shut,\n'
    || E'    ''checked_on'', (select max(p.checked_at)::date from public.venue_products p\n'
    || E'                     where p.venue_id = v.id and p.status = ''live''),\n'
    || E'    ''website'', (select nullif(btrim(x.website), '''') from public.venues x\n'
    || E'                  where x.id = v.id and x.listing_tier = ''verified''\n'
    || E'                    and x.website ~* ''^https?://''));';
begin
  if position('''checked_on''' in d) > 0 then
    return;
  end if;
  if position(marker in d) = 0 then
    raise exception 'page_prices: the place to add checked_on was not found';
  end if;
  execute replace(d, marker, added);
end
$mig$;
