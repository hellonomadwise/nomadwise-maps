-- ============================================================
-- Migration 270: the Performance chart follows the period buttons.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: the By month chart should change with Last
-- 30 days, 3 months and 12 months. owner_performance now returns
-- 'unit' and the chart's points to match:
--   30 days   30 points, one per day     (unit 'day')
--   3 months  13 points, one per week    (unit 'week', weeks from Monday)
--   12 months 12 points, one per month   (unit 'month')
-- The last point is the one still running (today, this week, this
-- month). The points stay under 'months' with their start date as
-- 'month', so the app reads them as before.
-- ============================================================

do $$
declare d text;
begin
  select pg_get_functiondef('public.owner_performance(uuid,integer)'::regprocedure) into d;
  if position('''unit''' in d) = 0 then
    d := replace(d,
      '  rule   jsonb := public.free_enquiry_rule();',
      '  rule   jsonb := public.free_enquiry_rule();
  step   interval;
  last_  timestamp;
  first_ timestamp;');
    d := replace(d,
      '  v := public.billing_venue(p_venue, false);   -- the owner, or a founder',
      '  v := public.billing_venue(p_venue, false);   -- the owner, or a founder
  step := case d when 30 then interval ''1 day'' when 91 then interval ''1 week''
                 else interval ''1 month'' end;
  last_ := case d when 30 then today::timestamp
                  when 91 then date_trunc(''week'', today::timestamp)
                  else date_trunc(''month'', today::timestamp) end;
  first_ := last_ - step * (case d when 30 then 29 when 91 then 12 else 11 end);');
    d := replace(d, $q$    'months', ($q$,
      $q$    'unit', case d when 30 then 'day' when 91 then 'week' else 'month' end,
    'months', ($q$);
    d := replace(d, $q$and day < m + interval '1 month'), 0),$q$, $q$and day < m + step), 0),$q$);
    d := replace(d, $q$and day < m + interval '1 month'), 0))$q$, $q$and day < m + step), 0))$q$);
    d := replace(d,
      $q$from (select generate_series(date_trunc('month', today::timestamp) - interval '5 months',
                                     date_trunc('month', today::timestamp),
                                     interval '1 month')::date as m) mm),$q$,
      $q$from (select generate_series(first_, last_, step)::date as m) mm),$q$);
    if position('''unit''' in d) = 0 or position('generate_series(first_, last_, step)' in d) = 0
       or position('m + step), 0))' in d) = 0 or position('m + step), 0),' in d) = 0 then
      raise exception 'owner_performance did not change as expected';
    end if;
    execute d;
  end if;
end $$;
