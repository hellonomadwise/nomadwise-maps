-- ============================================================
-- Migration 111: see and control what Google costs, per job.
-- (Applied automatically by the build; nothing to paste.)
--
-- The Google calls page now explains each day's spend job by job, and
-- a founder can, from the app:
--   * change the daily limit on Google lookups (was a database edit);
--   * pause one job (the nightly refresh, the website sync, the
--     website push, the photo jobs, or visitors in the app). A paused
--     job asks Google nothing until it is switched back on; the rest
--     keep running. Paused calls are counted apart, like the limit.
--
-- google_budget() returns the same as before plus 'paused': the jobs
-- switched off, which the jobs and the app read before calling Google.
-- A pause is kept in api_limits as 'pause:<job>' = 1.
-- ============================================================

create or replace function public.google_budget()
returns jsonb language sql stable security definer set search_path = public as $$
  with lim as (
    select
      coalesce((select value from api_limits where key = 'places_gbp_per_day'), 10) as gbp,
      coalesce((select value from api_limits where key = 'map_loads_per_day'), 2300) as maps,
      coalesce((select value from api_limits where key = 'usd_to_gbp'), 0.75) as fx
  ), today as (
    select
      coalesce(sum(case when sku <> 'Dynamic Maps'
                        then calls * api_list_price_usd(sku) / 1000.0 end), 0) as usd,
      coalesce(sum(case when sku = 'Dynamic Maps' then calls end), 0) as map_loads
    from api_usage
    where day = (now() at time zone 'utc')::date
  )
  select jsonb_build_object(
    'spent_gbp', round((today.usd * lim.fx)::numeric, 2),
    'limit_gbp', lim.gbp,
    'over', today.usd * lim.fx >= lim.gbp,
    'map_loads', today.map_loads,
    'map_cap', lim.maps,
    'fx', lim.fx,
    'paused', coalesce((select jsonb_agg(substr(key, 7) order by key)
                          from api_limits
                         where key like 'pause:%' and value >= 1), '[]'::jsonb))
  from lim, today
$$;
revoke all on function public.google_budget() from public;
grant execute on function public.google_budget() to anon, authenticated, service_role;

-- A founder changes the daily limit or pauses a job.
create or replace function public.admin_set_google_control(p_key text, p_value numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  if p_key = 'places_gbp_per_day' then
    if p_value is null or p_value < 1 or p_value > 500 then
      raise exception 'The daily limit must be between £1 and £500.';
    end if;
  elsif p_key in ('pause:nightly refresh', 'pause:website sync',
                  'pause:website push', 'pause:photo suggestions',
                  'pause:photo check', 'pause:app') then
    p_value := case when coalesce(p_value, 0) >= 1 then 1 else 0 end;
  else
    raise exception 'Unknown setting.';
  end if;
  insert into public.api_limits (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return public.google_budget();
end $$;
revoke all on function public.admin_set_google_control(text, numeric) from public, anon;
grant execute on function public.admin_set_google_control(text, numeric) to authenticated;
