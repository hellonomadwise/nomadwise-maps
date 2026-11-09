-- ============================================================
-- Migration 298: Home's numbers read faster
-- ============================================================
-- Jonathan, 9 Nov 2026: opening Home sometimes showed "The numbers
-- could not be read ... statement timeout" before the page came. The
-- Google impressions part of admin_home() went through the whole
-- page_google_days table (260,000 rows) once for every month shown,
-- six times over; page views the same. Now each is one pass over the
-- six months, grouped by month, with an index on the day.
-- ============================================================

create index if not exists page_google_days_day
  on public.page_google_days (day) include (impressions);

select public.pm_patch_fn('public.admin_home()',
$a$    'google', (
      select jsonb_agg(jsonb_build_object(
               'month', to_char(m, 'YYYY-MM-DD'),
               'n', coalesce((select sum(g.impressions) from public.page_google_days g
                               where g.day >= m and g.day < m + interval '1 month'), 0))
             order by m)
        from generate_series(this_m - interval '6 months', this_m - interval '1 month',
                             interval '1 month') m),$a$,
$a$    'google', (
      -- one pass, grouped by month (migration 298)
      with g as (
        select date_trunc('month', d.day)::date as m, sum(d.impressions) as n
          from public.page_google_days d
         where d.day >= (this_m - interval '6 months')::date and d.day < this_m
         group by 1)
      select jsonb_agg(jsonb_build_object(
               'month', to_char(s.m, 'YYYY-MM-DD'),
               'n', coalesce(g.n, 0))
             order by s.m)
        from (select generate_series(this_m - interval '6 months', this_m - interval '1 month',
                                     interval '1 month')::date as m) s
        left join g on g.m = s.m),$a$,
$m$-- one pass, grouped by month (migration 298)$m$);

select public.pm_patch_fn('public.admin_home()',
$a$    'views', (
      select jsonb_agg(jsonb_build_object(
               'month', to_char(m, 'YYYY-MM-DD'),
               'n', coalesce((select sum(c.n) from public.page_counts c
                               where c.kind = 'view' and c.day >= m
                                 and c.day < m + interval '1 month'), 0))
             order by m)
        from generate_series(this_m - interval '6 months', this_m - interval '1 month',
                             interval '1 month') m),$a$,
$a$    'views', (
      -- one pass, grouped by month (migration 298, views)
      with v as (
        select date_trunc('month', c.day)::date as m, sum(c.n) as n
          from public.page_counts c
         where c.kind = 'view'
           and c.day >= (this_m - interval '6 months')::date and c.day < this_m
         group by 1)
      select jsonb_agg(jsonb_build_object(
               'month', to_char(s.m, 'YYYY-MM-DD'),
               'n', coalesce(v.n, 0))
             order by s.m)
        from (select generate_series(this_m - interval '6 months', this_m - interval '1 month',
                                     interval '1 month')::date as m) s
        left join v on v.m = s.m),$a$,
$m$migration 298, views$m$);
