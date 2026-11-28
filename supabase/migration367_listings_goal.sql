-- Migration 367: the listings goal, and new pages live each day.
--
-- Jonathan, 28 Nov 2026: "Can you create a tracker that shows bar chart
-- daily" (new pages live, in Nomad Maps), then: "Similar like this
-- [the Home charts]. Want to track progress. I want a goal of getting
-- 10k listings live so want to gamify to get this done".
--
-- admin_listings_goal() gives Home and Pages:
--   live          pages live now (website_status 'released', as Home's
--                 "spaces live")
--   goal, daily   from sync_settings 'listings_goal' (10,000; 25 a day,
--                 which reaches 10,000 in about a year from today)
--   days          the last 30 London days: new pages live each day
--                 (venues.new_page_live_at, set when a page approved
--                 in Pages first goes live, migration 178), 0 where none
--   streak        days in a row up to today with at least one new page
--                 (today not counted against it while it is still 0)
--   best          the best day ever, and its count
--   pace          new pages a day over the last 14 days

insert into public.sync_settings (key, value)
values ('listings_goal', '{"goal": 10000, "daily": 25}'::jsonb)
on conflict (key) do nothing;

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

  return jsonb_build_object(
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
