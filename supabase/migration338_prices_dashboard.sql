-- Prices overview (Jonathan, 22 Nov 2026): "an overview dashboard ...
-- how many listings have prices on their pages, and how many products
-- in each ... over time, on a daily bar chart cumulative ... for the
-- coworking spaces, how many as % and by area/region/location".
--
-- One read for the whole screen. A "listing" is a page that is live on
-- nomadwise.io; it "has prices" when it carries at least one live
-- product (a product may say "Price on request"). The days count each
-- product from the day it was added, and each listing from the day of
-- its first product, so the bars only ever grow.
create or replace function public.admin_prices_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  cards   jsonb;
  all_on  boolean;
  out_    jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Team only.';
  end if;
  select value into cards from public.sync_settings where key = 'price_cards';
  all_on := coalesce((cards->>'on')::boolean, false);

  with live as (
    select v.id, v.type, v.webflow_slug,
           coalesce(nullif(btrim(v.country), ''), 'Unknown') as country,
           coalesce(nullif(btrim(v.city), ''), 'Unknown') as city,
           coalesce(nullif(btrim(v.neighbourhood), ''), '') as area
      from public.venues v
     where v.website_status = 'released'
  ),
  prod as (
    select p.venue_id, p.category, p.amount, p.created_at::date as d
      from public.venue_products p
      join live l on l.id = p.venue_id
     where p.status = 'live'
  ),
  per as (
    select venue_id, count(*) as n, min(d) as first_d,
           count(*) filter (where amount is not null) as priced
      from prod group by venue_id
  ),
  days as (
    select g::date as d
      from generate_series(
             greatest((select min(d) from prod), current_date - 89),
             current_date, interval '1 day') g
  ),
  series as (
    select d.d,
           (select count(*) from per where first_d <= d.d) as listings,
           (select count(*) from prod where prod.d <= d.d) as products
      from days d
  ),
  places as (
    select l.country, l.city, l.area,
           count(*) as pages,
           count(per.venue_id) as with_prices,
           coalesce(sum(per.n), 0) as products
      from live l left join per on per.venue_id = l.id
     where l.type = 'coworking'
     group by 1, 2, 3
  ),
  sizes as (
    select case when n >= 10 then '10 or more'
                when n >= 5 then '5 to 9'
                when n >= 2 then '2 to 4'
                else '1' end as bucket,
           min(n) as ord, count(*) as listings
      from per join live l on l.id = per.venue_id
     where l.type = 'coworking'
     group by 1
  )
  select jsonb_build_object(
    'coworking', jsonb_build_object(
      'pages', (select count(*) from live where type = 'coworking'),
      'with_prices', (select count(*) from per join live l on l.id = per.venue_id
                       where l.type = 'coworking'),
      'showing', (select count(*) from per join live l on l.id = per.venue_id
                   where l.type = 'coworking'
                     and (all_on or coalesce(cards->'slugs', '[]'::jsonb) ? l.webflow_slug))),
    'cafes', jsonb_build_object(
      'pages', (select count(*) from live where type <> 'coworking'),
      'with_prices', (select count(*) from per join live l on l.id = per.venue_id
                       where l.type <> 'coworking')),
    'products', jsonb_build_object(
      'all', (select count(*) from prod),
      'priced', (select count(*) from prod where amount is not null),
      'on_request', (select count(*) from prod where amount is null),
      'coworking', (select count(*) from prod where category = 'coworking'),
      'meeting_room', (select count(*) from prod where category = 'meeting_room'),
      'private_office', (select count(*) from prod where category = 'private_office'),
      'other', (select count(*) from prod
                 where category not in ('coworking','meeting_room','private_office'))),
    'sizes', coalesce((select jsonb_agg(jsonb_build_object(
                'bucket', bucket, 'listings', listings) order by ord) from sizes), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(jsonb_build_object(
                'd', d, 'listings', listings, 'products', products) order by d)
                from series), '[]'::jsonb),
    'places', coalesce((select jsonb_agg(jsonb_build_object(
                'country', country, 'city', city, 'area', area, 'pages', pages,
                'with_prices', with_prices, 'products', products)) from places), '[]'::jsonb)
  ) into out_;
  return out_;
end $function$;

revoke all on function public.admin_prices_dashboard() from public, anon;
grant execute on function public.admin_prices_dashboard() to authenticated;
