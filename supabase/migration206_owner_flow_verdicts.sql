-- ============================================================
-- Migration 206: the Owner flow tells you what is a problem and
-- what to press.
--
-- Jonathan, 4 Nov 2026: "what I'm ultimately wanting to do is to be
-- able to click into something ... and go, okay, what is the
-- bottleneck that is sitting here? ... how do we go from, this is a
-- problem, to these are the steps that we can take in order to
-- improve it." Each stage on the map now has a target (editable in
-- the app), a verdict against it, the signals behind the verdict,
-- and steps with buttons. "Build it" steps are asks the Monday
-- review carries to the Daily page in Notion.
--
--   owner_flow_targets   one row per measure: the number that counts
--                        as healthy. Edited in the app.
--   owner_flow_asks      "build it" taps: stage, item, when, by whom;
--                        done_at once Jonathan and Leonie decided.
--   admin_owner_flow_target_set(key, value)
--   admin_owner_flow_ask(stage, item)      insert an ask (no duplicates
--                                          while one is open)
--   admin_owner_flow_signals(as_of)        the numbers behind verdicts
--   admin_owner_flow(as_of)                now also returns targets,
--                                          signals and open asks
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create table if not exists public.owner_flow_targets (
  key        text primary key,
  value      numeric not null,
  label      text not null,
  unit       text not null default '',    -- '%', 'a week', 'a month', 'h'
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.owner_flow_targets enable row level security;
revoke all on public.owner_flow_targets from public, anon, authenticated;
insert into public.owner_flow_targets (key, value, label, unit) values
  ('outreach_sent_week',  25, 'Outreach emails sent a week',                      'a week'),
  ('claims_month',         5, 'Claims a month',                                   'a month'),
  ('claim_rate',          25, 'Claim-page visitors who claim',                    '%'),
  ('login_rate',          60, 'Claimed owners who log in within 14 days',         '%'),
  ('edit_rate',           60, 'Logged-in owners who submit an edit',              '%'),
  ('review_24h',          90, 'Edits reviewed within 24 hours',                   '%'),
  ('return_30',           50, 'Owners back within 30 days of approval',           '%'),
  ('quiet_share',         25, 'Approved owners who are quiet or dormant, at most','%'),
  ('premium_count',        1, 'Paying owners',                                    '')
on conflict (key) do nothing;

create or replace function public.admin_owner_flow_target_set(p_key text, p_value numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;
  update public.owner_flow_targets
     set value = p_value, updated_at = now(), updated_by = coalesce(public.chat_team_name(), 'Jonathan')
   where key = p_key;
  return jsonb_build_object('key', p_key, 'value', p_value);
end $$;
grant execute on function public.admin_owner_flow_target_set(text, numeric) to authenticated;

create table if not exists public.owner_flow_asks (
  id        uuid primary key default gen_random_uuid(),
  stage     text not null,
  item      text not null,
  asked_at  timestamptz not null default now(),
  asked_by  text,
  done_at   timestamptz,
  note      text
);
alter table public.owner_flow_asks enable row level security;
revoke all on public.owner_flow_asks from public, anon, authenticated;

create or replace function public.admin_owner_flow_ask(p_stage text, p_item text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;
  select id into v_id from public.owner_flow_asks where stage = p_stage and item = p_item and done_at is null limit 1;
  if v_id is null then
    insert into public.owner_flow_asks (stage, item, asked_by)
    values (p_stage, p_item, coalesce(public.chat_team_name(), 'Jonathan'))
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'new', true);
  end if;
  return jsonb_build_object('id', v_id, 'new', false);
end $$;
grant execute on function public.admin_owner_flow_ask(text, text) to authenticated;

-- The numbers behind each verdict, as of a moment.
create or replace function public.admin_owner_flow_signals(p_as_of timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t timestamptz := coalesce(p_as_of, now());
  r jsonb;
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;
  with real_visitors as (
    select v.anon_id, v.first_at
      from (
        select anon_id, min(created_at) as first_at,
               bool_or(coalesce(props->>'from', '') not like '/blog/%') as not_from_blog
          from public.app_events
         where name = 'claim_opened' and created_at <= t
           and anon_id not in (select anon_id from public.team_devices)
           and anon_id not in (select anon_id from public.bot_visitors)
         group by 1) v
     where v.not_from_blog or v.anon_id in (
        select distinct anon_id from public.app_events
         where name in ('claim_step', 'claim_typed', 'claim_free', 'claim_to_payment', 'claim_space') and created_at <= t)
  ), claimers as (
    select distinct anon_id from public.app_events
     where name in ('claim_free', 'claim_to_payment') and created_at <= t
  ), stops as (
    -- where the visitors who did not claim were last seen on the claim page
    select coalesce(
             (select e.props->>'step' from public.app_events e
               where e.anon_id = rv.anon_id and e.name = 'claim_left' and e.created_at <= t
               order by e.created_at desc limit 1),
             (select coalesce(e.props->>'to', e.props->>'step') from public.app_events e
               where e.anon_id = rv.anon_id and e.name = 'claim_step' and e.created_at <= t
               order by e.created_at desc limit 1),
             'opened') as step
      from real_visitors rv
     where rv.first_at > t - interval '30 days'
       and rv.anon_id not in (select anon_id from claimers)
  )
  select jsonb_build_object(
    'visitors_30d', (select count(*) from real_visitors where first_at > t - interval '30 days'),
    'claims_30d', (select count(distinct lower(owner_email)) from public.listing_claims
                    where created_at > t - interval '30 days' and created_at <= t
                      and status in ('free', 'paid')
                      and lower(owner_email) not in (select email from public.owner_flow_team_emails)
                      and lower(owner_email) not like '%nomadwise%'
                      and coalesce(owner_name, '') not ilike '%test%'),
    'claim_stops_30d', (select coalesce(jsonb_object_agg(step, n), '{}'::jsonb) from (select step, count(*) n from stops group by 1) s),
    'from_outreach_30d', (select count(distinct lower(lc.owner_email)) from public.listing_claims lc
                           where lc.created_at > t - interval '30 days' and lc.created_at <= t and lc.status in ('free', 'paid')
                             and exists (select 1 from public.space_contacts sc where lower(sc.email) = lower(lc.owner_email)
                                           and sc.last_out_at is not null and sc.last_out_at < lc.created_at)),
    'outreach_sent_7d', (select count(*) from public.outreach_messages where direction = 'out' and at > t - interval '7 days' and at <= t),
    'outreach_sent_30d', (select count(*) from public.outreach_messages where direction = 'out' and at > t - interval '30 days' and at <= t),
    'outreach_replies_30d', (select count(*) from public.outreach_messages where direction = 'in' and at > t - interval '30 days' and at <= t),
    'outreach_picked_waiting', (select count(*) from public.space_contacts
                                 where notes like '%Outreach 5%' and notes not like '%left off%' and last_out_at is null),
    'outreach_ready', (select count(*) from public.space_contacts c join public.venues v on v.id = c.venue_id
                        where c.stage = 'new' and c.email is not null and c.last_out_at is null and not coalesce(c.is_test, false)
                          and c.unsubscribed_at is null and c.aside_at is null and v.website_status = 'released' and v.closed_seen_at is null),
    'seq_step1_30d', (select count(*) from public.sequence_sends where step = 1 and sent_at > t - interval '30 days' and sent_at <= t),
    'seq_step2_30d', (select count(*) from public.sequence_sends where step = 2 and sent_at > t - interval '30 days' and sent_at <= t),
    'seq_enabled', (select coalesce(bool_and(enabled), false) from public.sequences),
    'open_asks', (select coalesce(jsonb_agg(jsonb_build_object('stage', stage, 'item', item, 'at', asked_at) order by asked_at), '[]'::jsonb)
                   from public.owner_flow_asks where done_at is null),
    'targets', (select jsonb_object_agg(key, jsonb_build_object('value', value, 'label', label, 'unit', unit)) from public.owner_flow_targets)
  ) into r;
  return r;
end $$;
grant execute on function public.admin_owner_flow_signals(timestamptz) to authenticated;
