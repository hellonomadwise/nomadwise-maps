-- Prices overview counts what visitors can see (Jonathan, 22 Nov 2026,
-- looking at the first version: "but are these pages with prices, that
-- are live?"). They were not: the chart counted pages that have
-- products stored. A page shows its prices only when its price cards
-- are on (sync_settings 'price_cards'), so the day each page was
-- switched on is now kept, and the overview's headline, chart and
-- by-place list are about pages showing prices to visitors.
create table if not exists public.price_cards_since (
  slug  text primary key,
  since date not null default current_date
);
alter table public.price_cards_since enable row level security;

-- The pages on the list today. The 16 added on 22 Nov 2026 are known;
-- the rest were switched on 21 Nov 2026 (two of them possibly earlier).
insert into public.price_cards_since (slug, since)
select s,
       case when s = any (array[
         'england-london-wework-123-buckingham-palace-road','england-london-halkin',
         'england-london-regus-euston','england-london-spaces-angel-islington',
         'england-london-elementa','england-london-go-bermondsey',
         'england-london-fora-white-collar-factory','england-london-argyll-1-cornhill',
         'england-london-argyll-1-king-william-street','england-london-argyll-85-gresham-street',
         'england-london-argyll-octagon-point','england-london-fora-sixty-london-wall',
         'england-london-fora-warnford-court','england-london-usco-monument',
         'england-london-industrious-70-st-mary-axe',
         'england-london-worklife-aldersgate-street-office-space-coworking'])
            then date '2026-11-22' else date '2026-11-21' end
  from public.sync_settings ss,
       jsonb_array_elements_text(coalesce(ss.value->'slugs', '[]'::jsonb)) s
 where ss.key = 'price_cards'
on conflict (slug) do nothing;

-- From now on: a page added to the list is dated the day it is added.
create or replace function public.price_cards_since_note()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.key = 'price_cards' then
    insert into public.price_cards_since (slug)
    select s from jsonb_array_elements_text(coalesce(new.value->'slugs', '[]'::jsonb)) s
    on conflict (slug) do nothing;
  end if;
  return new;
end $function$;

drop trigger if exists price_cards_since_note on public.sync_settings;
create trigger price_cards_since_note
  after insert or update on public.sync_settings
  for each row execute function public.price_cards_since_note();

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
           (select count(*) from prod where prod.d <= d.d) as products
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
                'products', products) order by d)
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
