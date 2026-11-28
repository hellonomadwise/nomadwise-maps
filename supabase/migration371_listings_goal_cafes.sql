-- Migration 371: cafes on the "What 10,000 could mean" screen.
--
-- Jonathan, 28 Nov 2026: "Haven't looked at how we could monetise
-- cafes", then "Okay go on cafes" after a mockup. The model gains
-- 'cafes' (views by month from PostHog plus guessed rates) and
-- 'cafe_stats' (live cafe pages, claimed cafe pages, cities with enough
-- cafes for a featured spot). Views were read from PostHog on 28 Nov
-- 2026 (pageviews of the 668 live cafe pages, 30-day blocks ending 27
-- Sep, 27 Oct and 28 Nov). A weekly task refreshes them.
-- Guesses: EUR 0.01 a view from stay and eSIM links (a tenth of what an
-- eSIM article earns a view), one EUR 10 a month featured spot in each
-- city with 10 or more cafes, cafe Premium about EUR 4 a month with 10%
-- of claimed cafes paying.

update public.sync_settings
   set value = value || jsonb_build_object('cafes', '{
     "as_of": "2026-11-28",
     "months": [
       {"to": "2026-09-27", "views": 1609, "people": 1038},
       {"to": "2026-10-27", "views": 1318, "people": 867},
       {"to": "2026-11-28", "views": 1168, "people": 822}
     ],
     "per_view_eur": 0.01,
     "featured_eur_month": 10,
     "featured_min_cafes": 10,
     "premium_eur_month": 4,
     "premium_share": 0.10
   }'::jsonb)
 where key = 'listings_goal' and not (value ? 'cafes');

create or replace function public.admin_listings_goal()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Europe/London')::date;
  cfg   jsonb := coalesce((select s.value from public.sync_settings s
                            where s.key = 'listings_goal'), '{}'::jsonb);
  days  jsonb;
  streak int := 0;
  d     date;
  best  record;
  pace  numeric;
  money jsonb;
  req60 int;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;

  with per as (
    select (v.new_page_live_at at time zone 'Europe/London')::date as day,
           count(*) as n,
           count(*) filter (where v.type = 'coworking') as coworking
      from public.venues v
     where v.new_page_live_at is not null
     group by 1)
  select jsonb_agg(jsonb_build_object(
           'day', g.day::date, 'n', coalesce(per.n, 0),
           'coworking', coalesce(per.coworking, 0)) order by g.day)
    into days
    from generate_series(today - 29, today, interval '1 day') g(day)
    left join per on per.day = g.day::date;

  -- The streak: today counts once it has one; until then it runs to
  -- yesterday.
  d := today;
  if not exists (select 1 from public.venues v
                  where (v.new_page_live_at at time zone 'Europe/London')::date = today) then
    d := today - 1;
  end if;
  while exists (select 1 from public.venues v
                 where (v.new_page_live_at at time zone 'Europe/London')::date = d) loop
    streak := streak + 1;
    d := d - 1;
  end loop;

  select (v.new_page_live_at at time zone 'Europe/London')::date as day, count(*) as n
    into best
    from public.venues v
   where v.new_page_live_at is not null
   group by 1 order by 2 desc, 1 desc limit 1;

  select round(count(*)::numeric / 14, 1) into pace
    from public.venues v
   where v.new_page_live_at >= (today - 13)::timestamp at time zone 'Europe/London';

  -- What 10,000 could mean: today's rates, read live.
  begin
    money := public.admin_money();
  exception when others then
    money := '{}'::jsonb;
  end;
  select count(*) into req60
    from public.enquiries e
   where coalesce(e.is_test, false) = false
     and e.created_at > now() - interval '60 days';

  return jsonb_build_object(
    'requests_60', req60,
    'claimed', coalesce((money ->> 'claimed')::int, 0),
    'premium', coalesce((money ->> 'verified')::int, 0),
    'paying', coalesce((money ->> 'paying')::int, 0),
    'mrr_eur', coalesce((money ->> 'mrr_eur')::numeric, 0),
    -- The assumptions behind the money lines, kept with the goal so
    -- they can be changed without a new app.
    'model', jsonb_build_object(
      'premium_share', coalesce((cfg ->> 'premium_share')::numeric, 0.10),
      'premium_eur_month', coalesce((cfg ->> 'premium_eur_month')::numeric, 7),
      'office_share', coalesce((cfg ->> 'office_share')::numeric, 0.15),
      'office_close', coalesce((cfg ->> 'office_close')::numeric, 0.067),
      'office_fee_eur', coalesce((cfg ->> 'office_fee_eur')::numeric, 3300),
      'desk_book', coalesce((cfg ->> 'desk_book')::numeric, 0.07),
      'desk_fee_eur', coalesce((cfg ->> 'desk_fee_eur')::numeric, 30),
      -- Fees by ticket size (migration 370): share of requests, share
      -- that book, our fee on each booking.
      'tiers', coalesce(cfg -> 'tiers', '[
        {"key": "small", "label": "Small", "what": "Hour, day pass, meeting room", "share": 0.60, "book": 0.12, "fee_eur": 5},
        {"key": "medium", "label": "Medium", "what": "Monthly desk, team for a few weeks", "share": 0.30, "book": 0.07, "fee_eur": 100},
        {"key": "high", "label": "High", "what": "Private office, team of four for a year", "share": 0.10, "book": 0.067, "fee_eur": 3300}
      ]'::jsonb),
      -- Cafes (migration 371): monthly views from PostHog, written into
      -- sync_settings by the weekly cafe views task, plus the guessed
      -- rates for the three ways cafe pages could earn.
      'cafes', coalesce(cfg -> 'cafes', '{}'::jsonb)),
    'cafe_stats', jsonb_build_object(
      'live', (select count(*) from public.venues v
                where v.website_status = 'released' and v.type = 'cafe'),
      'claimed', (select count(distinct c.venue_id) from public.listing_claims c
                    join public.venues v on v.id = c.venue_id
                   where v.website_status = 'released' and v.type = 'cafe'
                     and c.status not in ('abandoned', 'rejected')),
      'cities_featured', (select count(*) from (
          select lower(coalesce(nullif(v.city, ''), '?'))
            from public.venues v
           where v.website_status = 'released' and v.type = 'cafe'
           group by 1
          having count(*) >= coalesce((cfg -> 'cafes' ->> 'featured_min_cafes')::int, 10)) x)),
    'live', (select count(*) from public.venues v where v.website_status = 'released'),
    'live_coworking', (select count(*) from public.venues v
                        where v.website_status = 'released' and v.type = 'coworking'),
    'goal', coalesce((cfg ->> 'goal')::int, 10000),
    'daily', coalesce((cfg ->> 'daily')::int, 25),
    'days', coalesce(days, '[]'::jsonb),
    'streak', streak,
    'best_day', best.day,
    'best_n', coalesce(best.n, 0),
    'pace', coalesce(pace, 0),
    'today', today);
end $$;
revoke all on function public.admin_listings_goal() from public, anon;
grant execute on function public.admin_listings_goal() to authenticated;
