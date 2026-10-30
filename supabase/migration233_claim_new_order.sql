-- ============================================================
-- Migration 233: the claim page's new order, in Outreach.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 30 Oct 2026: the claim page (and nomadmaps.io/pricing,
-- which is now the same page) goes find your space, then the plans
-- with the price for its country, then your details. The steps have
-- new names in the events: 'plans' (step two) and 'details' (step
-- three). Before, it was find, 'about' (details), 'plan'.
-- claim_lookers() says how far a visitor got, for the Outreach line
-- "looked and left / got as far as ...":
--   3  chose a plan: reached 'details' now, or 'plan' before, or
--      pressed claim / pay
--   2  saw the plans: reached 'plans' now, or 'about' before (the
--      plans were shown under the details then)
--   1  began adding a space
-- Same function as migration 181 otherwise.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.claim_lookers(p_days integer default 60)
returns table (
  venue_id  uuid,
  last_at   timestamptz,
  opens     integer,
  visitors  integer,
  furthest  integer,
  secs      integer,
  from_path text,
  referrer  text,
  device    text
) language sql stable security definer set search_path = public as $$
  with ev as (
    select e.anon_id, e.name, e.props, e.created_at,
           coalesce(nullif(e.props ->> 'visit', ''),
                    e.anon_id || to_char(e.created_at, 'YYYYMMDDHH24')) as visit
      from public.app_events e
     where left(e.name, 6) = 'claim_'
       and e.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 60), 365)))
       and not exists (select 1 from public.team_devices t where t.anon_id = e.anon_id)
       -- nor a machine (migration 181)
       and not exists (select 1 from public.bot_visitors b where b.anon_id = e.anon_id)
  ),
  vis as (
    select min(ev.anon_id) as anon_id, ev.visit,
           min(ev.created_at) as at,
           max(ev.props ->> 'seed') filter (where ev.name = 'claim_opened') as seed,
           (array_agg(ev.props ->> 'space' order by ev.created_at desc)
              filter (where coalesce(ev.props ->> 'space', '') <> ''))[1] as space,
           max(ev.props ->> 'from') filter (where ev.name = 'claim_opened') as from_path,
           max(ev.props ->> 'referrer') filter (where ev.name = 'claim_opened') as referrer,
           max(ev.props ->> 'device') filter (where ev.name = 'claim_opened') as device,
           max(case when ev.name in ('claim_to_payment', 'claim_free') then 3
                    when ev.name = 'claim_step' and ev.props ->> 'to' in ('plan', 'details') then 3
                    when ev.name = 'claim_step' and ev.props ->> 'to' in ('about', 'plans') then 2
                    when ev.name = 'claim_typed' then 2
                    when ev.name = 'claim_step' and ev.props ->> 'to' = 'add_space' then 1
                    -- the step every event says it happened on (a
                    -- form picked up again starts where it was left)
                    when ev.props ->> 'step' in ('plan', 'details') then 3
                    when ev.props ->> 'step' in ('about', 'plans') then 2
                    when ev.props ->> 'step' = 'add_space' then 1
                    else 0 end) as furthest,
           max(case when (ev.props ->> 'secs') ~ '^[0-9]{1,6}$'
                    then (ev.props ->> 'secs')::integer else 0 end) as secs,
           bool_or(ev.name = 'claim_free') as done
      from ev
     group by ev.visit
  ),
  hit as (
    select vis.*, m.id as venue_id
      from vis
     cross join lateral (
            select v.id
              from public.venues v
             where (coalesce(vis.seed, '') <> '' and v.webflow_slug = vis.seed)
                or lower(v.name) = lower(coalesce(nullif(vis.space, ''), nullif(vis.seed, '')))
             order by (coalesce(vis.space, '') <> '' and lower(v.name) = lower(vis.space)) desc,
                      coalesce(v.webflow_slug = vis.seed, false) desc,
                      (v.webflow_cms_id is not null) desc, v.id
             limit 1) m
     where not vis.done
  )
  select h.venue_id, max(h.at), count(*)::integer, count(distinct h.anon_id)::integer,
         max(h.furthest)::integer, max(h.secs)::integer,
         (array_agg(h.from_path order by h.at desc))[1],
         (array_agg(h.referrer order by h.at desc))[1],
         (array_agg(h.device order by h.at desc))[1]
    from hit h
   group by h.venue_id;
$$;
revoke all on function public.claim_lookers(integer) from public, anon, authenticated;
grant execute on function public.claim_lookers(integer) to service_role;
