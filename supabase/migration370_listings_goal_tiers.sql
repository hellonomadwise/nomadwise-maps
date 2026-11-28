-- Migration 370: fees by ticket size on the goal card.
--
-- Jonathan, 28 Nov 2026: "is how the % of booking request plays out,
-- with small products, medium and higher ticket" and "Looking to refine
-- how mrr could look per 10,000 spaces". The fee line on "What 10,000
-- could mean" is now worked out per ticket size instead of one office
-- rate and one flat fee:
--   small   hour, day pass, meeting room (about EUR 50): 60% of requests,
--           12% book, fee EUR 5
--   medium  monthly desk, team for a few weeks (about EUR 1,000): 30%,
--           7% book, fee EUR 100
--   high    private office, team of four for a year: 10%, 1 in 15
--           becomes a deal, fee EUR 3,300
-- The split comes from sorting the 13 real people who sent the 18
-- requests in the last 120 days (8 small, 3 medium, 1 high, and one
-- asking both); one day pass is known to have booked. Booking rates and
-- fees are guesses. They live in sync_settings 'listings_goal' -> 'tiers'
-- and can be changed there without a new app. The old office and desk
-- keys stay in the model for older apps.

update public.sync_settings
   set value = value || jsonb_build_object('tiers', '[
     {"key": "small", "label": "Small", "what": "Hour, day pass, meeting room", "share": 0.60, "book": 0.12, "fee_eur": 5},
     {"key": "medium", "label": "Medium", "what": "Monthly desk, team for a few weeks", "share": 0.30, "book": 0.07, "fee_eur": 100},
     {"key": "high", "label": "High", "what": "Private office, team of four for a year", "share": 0.10, "book": 0.067, "fee_eur": 3300}
   ]'::jsonb)
 where key = 'listings_goal' and not (value ? 'tiers');

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
      ]'::jsonb)),
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
