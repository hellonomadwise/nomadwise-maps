-- Migration 337: the request pop-up starts on a day the space is open
-- (Jonathan, 22 Nov 2026). On a Saturday it offered Sunday for a Fora
-- building, which is closed at weekends.
--
-- page_prices() also returns closed_days: the days of the week the
-- space is closed, read from the opening hours already held for it.
-- prices.js moves the starting date on to the next open day. Nothing
-- else in what it returns changes; the visitor can still pick any date.

create or replace function public.page_prices(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  cfg    jsonb;
  slug_  text := lower(btrim(coalesce(p_slug, '')));
  v      record;
  items  jsonb;
  closed jsonb;
  hrs    jsonb;
  shut   jsonb := '[]'::jsonb;
begin
  if slug_ = '' or length(slug_) > 200 then
    return jsonb_build_object('show', false);
  end if;

  select x.id, x.name, x.owner_reopens_on, x.g_details into v
    from public.venues x
   where x.webflow_slug = slug_
   limit 1;
  if v.id is null then
    select x.id, x.name, x.owner_reopens_on, x.g_details into v
      from public.venues x
     where lower(x.webflow_slug) = slug_
     limit 1;
  end if;
  if v.id is null then
    return jsonb_build_object('show', false);
  end if;
  if v.owner_reopens_on > current_date then
    closed := jsonb_build_object('space', v.name, 'reopens_on', v.owner_reopens_on);
  end if;

  select value into cfg from public.sync_settings where key = 'price_cards';
  if not coalesce((cfg ->> 'on')::boolean, false)
     and not coalesce(cfg -> 'slugs', '[]'::jsonb) ? slug_ then
    return jsonb_build_object('show', false, 'closed', closed);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'name', p.name,
           'category', coalesce(nullif(p.category, ''), 'coworking'),
           'amount', p.amount,
           'currency', p.currency,
           'label', p.price_label,
           'from', coalesce(p.starting_from, false),
           'vat_included', p.vat_included,
           'details', coalesce(p.details, '[]'::jsonb))
           order by p.position, p.created_at), '[]'::jsonb)
    into items
    from public.venue_products p
   where p.venue_id = v.id and p.status = 'live';

  -- The days of the week the space is closed, as the browser numbers
  -- them (0 = Sunday ... 6 = Saturday), from its opening hours. Only
  -- when all seven days are known and it is open on at least one, so a
  -- gap in the hours never rules a day out.
  hrs := public.owner_google_hours(v.g_details);
  if (select count(*) from jsonb_object_keys(hrs)) = 7 then
    select coalesce(jsonb_agg(d.n order by d.n), '[]'::jsonb) into shut
      from (values ('sun', 0), ('mon', 1), ('tue', 2), ('wed', 3),
                   ('thu', 4), ('fri', 5), ('sat', 6)) as d(k, n)
     where lower(btrim(hrs ->> d.k)) = 'closed';
    if jsonb_array_length(shut) = 7 then
      shut := '[]'::jsonb;
    end if;
  end if;

  return jsonb_build_object(
    'show', jsonb_array_length(items) > 0,
    'space', v.name,
    'prices', items,
    'closed', closed,
    'closed_days', shut);
end $function$;

revoke all on function public.page_prices(text) from public;
grant execute on function public.page_prices(text) to anon, authenticated;
