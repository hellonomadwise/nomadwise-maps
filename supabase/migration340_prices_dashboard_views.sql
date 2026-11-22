-- Prices overview: how many visitors can see prices, and whether that
-- brings requests (Jonathan, 22 Nov 2026: "the most important should be
-- how many customers can actually view. we want to know and assess
-- whether increasing product visibility increases requests").
--
-- Adds, from numbers Nomad Maps already keeps: views of coworking pages
-- (page_counts) split by whether the page showed its prices that day,
-- requests (enquiries) split the same way, the last 30 days of both,
-- and the most viewed pages that have prices but do not show them yet.
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
           (all_on or coalesce(cards->'slugs', '[]'::jsonb) ? v.webflow_slug) as on_list,
           (select s.since from public.price_cards_since s
             where s.slug = v.webflow_slug) as since,
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
  -- A page shows its prices to visitors when it has a product and its
  -- price cards are on; from the later of the two days.
  shown as (
    select per.venue_id, per.n,
           greatest(per.first_d, coalesce(l.since, per.first_d)) as from_d
      from per join live l on l.id = per.venue_id
     where l.type = 'coworking' and l.on_list
  ),
  -- Views: one per visitor session and page, counted by the listing
  -- page itself (page_counts, kind 'view'). Coworking pages only.
  pv as (
    select c.venue_id, c.day, c.n,
           exists (select 1 from shown s
                    where s.venue_id = c.venue_id and s.from_d <= c.day) as shown
      from public.page_counts c
      join live l on l.id = c.venue_id
     where c.kind = 'view' and l.type = 'coworking'
       and c.day >= current_date - 89
  ),
  -- Requests sent from coworking pages, and whether that page showed
  -- its prices on the day.
  rq as (
    select e.venue_id, (e.created_at at time zone 'utc')::date as day,
           exists (select 1 from shown s
                    where s.venue_id = e.venue_id
                      and s.from_d <= (e.created_at at time zone 'utc')::date) as shown
      from public.enquiries e
      join live l on l.id = e.venue_id
     where l.type = 'coworking'
       and e.created_at >= current_date - 89
  ),
  waiting as (
    select l.id, v.name, l.city, l.country, per.n as products,
           (select coalesce(sum(n), 0) from pv where pv.venue_id = l.id
              and pv.day >= current_date - 29) as views
      from live l
      join per on per.venue_id = l.id
      join public.venues v on v.id = l.id
     where l.type = 'coworking' and not l.on_list
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
           (select count(*) from shown where from_d <= d.d) as showing,
           (select count(*) from prod where prod.d <= d.d) as products,
           (select coalesce(sum(n), 0) from pv where pv.day = d.d and pv.shown) as views_shown,
           (select coalesce(sum(n), 0) from pv where pv.day = d.d) as views_all,
           (select count(*) from rq where rq.day = d.d) as requests
      from days d
  ),
  places as (
    select l.country, l.city, l.area,
           count(*) as pages,
           count(per.venue_id) as with_prices,
           count(shown.venue_id) as showing,
           coalesce(sum(per.n), 0) as products
      from live l left join per on per.venue_id = l.id
      left join shown on shown.venue_id = l.id
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
      'showing', (select count(*) from shown),
      'showing_products', (select coalesce(sum(n), 0) from shown)),
    'last30', jsonb_build_object(
      'views_shown', (select coalesce(sum(n), 0) from pv where shown and day >= current_date - 29),
      'views_other', (select coalesce(sum(n), 0) from pv where not shown and day >= current_date - 29),
      'views_with_prices', (select coalesce(sum(pv.n), 0) from pv join per on per.venue_id = pv.venue_id
                             where pv.day >= current_date - 29),
      'requests_shown', (select count(*) from rq where shown and day >= current_date - 29),
      'requests_other', (select count(*) from rq where not shown and day >= current_date - 29)),
    'waiting', coalesce((select jsonb_agg(jsonb_build_object(
                'name', name, 'city', city, 'country', country,
                'products', products, 'views', views) order by views desc, name)
                from (select * from waiting order by views desc, name limit 15) w), '[]'::jsonb),
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
                'd', d, 'listings', listings, 'showing', showing,
                'products', products, 'views_shown', views_shown,
                'views_all', views_all, 'requests', requests) order by d)
                from series), '[]'::jsonb),
    'places', coalesce((select jsonb_agg(jsonb_build_object(
                'country', country, 'city', city, 'area', area, 'pages', pages,
                'with_prices', with_prices, 'showing', showing,
                'products', products)) from places), '[]'::jsonb)
  ) into out_;
  return out_;
end $function$;

revoke all on function public.admin_prices_dashboard() from public, anon;
grant execute on function public.admin_prices_dashboard() to authenticated;
