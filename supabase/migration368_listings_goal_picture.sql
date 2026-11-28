-- Migration 368: what 10,000 listings could mean, on the goal card.
--
-- Jonathan, 28 Nov 2026: "also want to somehow paint a picture on why
-- 10,000 is good. That it will mean a probability of average daily
-- requests of a certain average value, that it would mean an average
-- mrr of x based on xyz metrics".
--
-- admin_listings_goal() also returns today's rates, read live:
--   requests_60   requests from visitors in the last 60 days (tests out)
--   claimed, premium, paying, mrr_eur   from admin_money()
-- and the assumptions for the money lines, from sync_settings
-- 'listings_goal' (defaults below, changeable there):
--   premium_share      share of claimed spaces that pay for Premium (10%)
--   premium_eur_month  Premium a month, EUR 39 to 149 a year (EUR 7)
--   office_share       share of requests that are for an office (15%)
--   office_close       share of office requests that become a deal (1 in 15)
--   office_fee_eur     our fee on an office deal: 10% of a year for a
--                      team of four at GBP 600 a head, about EUR 3,300
--   desk_book          share of other requests that book (7%: 1 of the
--                      14 November requests reported booked)
--   desk_fee_eur       our fee on such a booking, 10% of a EUR 300 desk
-- The app works the lines out: requests a day at 10,000 from requests
-- per coworking page (requests come to coworking pages), the cafes kept
-- as they are; claimed spaces at today's claim rate; Premium and fees
-- from the assumptions.

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
      'desk_fee_eur', coalesce((cfg ->> 'desk_fee_eur')::numeric, 30)),
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
