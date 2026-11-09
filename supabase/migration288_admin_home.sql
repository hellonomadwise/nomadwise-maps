-- ============================================================
-- Migration 288: Home, where we stand (control centre)
-- ============================================================
-- Jonathan, 9 Nov 2026: "i dont think we should have today ... I
-- think I should have it where I have an overview of what things I
-- could do, and then I could choose what to do", with charts of what
-- we are working towards. Home is the first screen of the control
-- centre: where we stand (this function), then what you could do
-- (counts the control centre already reads, plus the Claim plan's).
--
-- admin_home() returns:
--   goal       Premium money a month (admin_money), paying, live, claimed
--   claims     spaces claimed a month, the last three months (the
--              current one so far); a space counts in the month of its
--              first claim; ours and test claims left out
--   google     times listing pages were shown in Google, by month,
--              the last six full months
--   views      listing page views, by month, the last six full months
--   outreach   messages we sent a week, from the week of Monday
--              5 Oct 2026 (at most the last twelve weeks), by way
--              (email, WhatsApp, Instagram, Facebook, contact form)
--              and whether the space has a page on nomadwise.io
--   plan       the Claim plan's counts and Round 1 (sent of all)
--   targets    claims_month, outreach_sent_week (owner_flow_targets)
-- Admins only. Reads only.
-- ============================================================

create or replace function public.admin_home()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  money  jsonb;
  plan   jsonb;
  today  date := (now() at time zone 'Europe/London')::date;
  this_m date := date_trunc('month', today)::date;
  wk0    date;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;

  money := public.admin_money();
  begin
    plan := public.admin_claim_plan();
  exception when others then
    plan := null;   -- the plan cannot be read: Home still shows the rest
  end;

  -- weeks from Monday 5 Oct 2026, at most the last twelve
  wk0 := greatest(date '2026-10-05',
                  date_trunc('week', today)::date - 11 * 7);

  return jsonb_build_object(
    'goal', jsonb_build_object(
      'mrr_eur', coalesce((money ->> 'mrr_eur')::numeric, 0),
      'paying', coalesce((money ->> 'paying')::int, 0),
      'live', coalesce((money ->> 'live')::int, 0),
      'claimed', coalesce((money ->> 'claimed')::int, 0),
      'target_eur', 1000),

    'claims', (
      with firsts as (
        select lc.venue_id, min(lc.created_at) as at
          from public.listing_claims lc
         where lc.status in ('free', 'paid') and lc.venue_id is not null
           and lower(coalesce(lc.owner_email, '')) not like '%nomadwise%'
           and lower(coalesce(lc.owner_email, '')) not in
               (select email from public.owner_flow_team_emails)
           and coalesce(lc.owner_name, '') not ilike '%test%'
           and not exists (select 1 from public.space_contacts c
                            where c.venue_id = lc.venue_id and c.is_test)
         group by lc.venue_id
      )
      select jsonb_agg(jsonb_build_object(
               'month', to_char(m, 'YYYY-MM-DD'),
               'n', (select count(*) from firsts f
                      where f.at >= m and f.at < m + interval '1 month'),
               'so_far', m = this_m)
             order by m)
        from generate_series(this_m - interval '2 months', this_m, interval '1 month') m),

    'google', (
      select jsonb_agg(jsonb_build_object(
               'month', to_char(m, 'YYYY-MM-DD'),
               'n', coalesce((select sum(g.impressions) from public.page_google_days g
                               where g.day >= m and g.day < m + interval '1 month'), 0))
             order by m)
        from generate_series(this_m - interval '6 months', this_m - interval '1 month',
                             interval '1 month') m),

    'views', (
      select jsonb_agg(jsonb_build_object(
               'month', to_char(m, 'YYYY-MM-DD'),
               'n', coalesce((select sum(c.n) from public.page_counts c
                               where c.kind = 'view' and c.day >= m
                                 and c.day < m + interval '1 month'), 0))
             order by m)
        from generate_series(this_m - interval '6 months', this_m - interval '1 month',
                             interval '1 month') m),

    'outreach', (
      with sent as (
        select date_trunc('week', m.at at time zone 'Europe/London')::date as wk,
               case m.subject
                 when 'WhatsApp' then 'whatsapp'
                 when 'Instagram' then 'instagram'
                 when 'Facebook' then 'facebook'
                 when 'Contact form' then 'form'
                 else 'email' end as way,
               (v.id is not null and coalesce(v.webflow_slug, '') <> '') as listed
          from public.outreach_messages m
          join public.space_contacts c on c.id = m.contact_id
          left join public.venues v on v.id = c.venue_id
         where m.direction = 'out' and m.send_error is null
           and not coalesce(c.is_test, false)
           and m.at >= wk0
      )
      select jsonb_agg(jsonb_build_object(
               'week', to_char(w, 'YYYY-MM-DD'),
               'listed', (select coalesce(jsonb_object_agg(way, n), '{}'::jsonb)
                            from (select way, count(*) n from sent
                                   where wk = w and listed group by 1) a),
               'new', (select coalesce(jsonb_object_agg(way, n), '{}'::jsonb)
                         from (select way, count(*) n from sent
                                where wk = w and not listed group by 1) b))
             order by w)
        from generate_series(wk0, date_trunc('week', today)::date, interval '7 days') w),

    'plan', case when plan is null then null else jsonb_build_object(
      'counts', coalesce(plan -> 'counts', '{}'::jsonb),
      'round1', coalesce((plan ->> 'round1')::int, 0),
      'round1_sent', coalesce((plan ->> 'round1_sent')::int, 0)) end,

    'targets', (select coalesce(jsonb_object_agg(t.key, t.value), '{}'::jsonb)
                  from public.owner_flow_targets t
                 where t.key in ('claims_month', 'outreach_sent_week'))
  );
end $$;

revoke all on function public.admin_home() from public, anon;
grant execute on function public.admin_home() to authenticated;
