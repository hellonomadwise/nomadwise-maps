-- ============================================================
-- Migration 203: the Owner flow, in the control centre.
--
-- Jonathan, 29 Oct 2026: a calm, minimal map of the space-owner
-- journey (lead in -> claim -> log in -> owner account -> edits ->
-- review -> keeps using -> Premium), run on real numbers, where the
-- blocked points show who is stuck there and what would push them
-- along. Built first as a Claude page; now in Nomad Maps for good.
--
--   owner_flow_team_emails   owner emails that are the team's own
--                            tests, never counted (plus any claim
--                            whose owner name says "test").
--   owner_flow_ticks         one row per owner email: the next step
--                            Jonathan ticked as done, and when.
--   admin_owner_flow()       everything the screen needs: one entry
--                            per real owner with the path they took
--                            through the map, the claim-page numbers,
--                            review speed, and the ticks.
--   admin_owner_flow_tick(email, done, step)   tick or untick.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create table if not exists public.owner_flow_team_emails (
  email text primary key,
  note  text
);
alter table public.owner_flow_team_emails enable row level security;
revoke all on public.owner_flow_team_emails from public, anon, authenticated;
insert into public.owner_flow_team_emails (email, note) values
  ('jonathanheavens@gmail.com', 'Jonathan'),
  ('jonnythebackpacker@gmail.com', 'Jonathan, test'),
  ('leonie.poelking@gmail.com', 'Leonie'),
  ('hellonomadwise@gmail.com', 'team')
on conflict (email) do nothing;

create table if not exists public.owner_flow_ticks (
  email   text primary key,
  step    text,
  done_at timestamptz not null default now(),
  done_by text
);
alter table public.owner_flow_ticks enable row level security;
revoke all on public.owner_flow_ticks from public, anon, authenticated;

create or replace function public.admin_owner_flow_tick(
  p_email text, p_done boolean default true, p_step text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;
  if coalesce(p_done, true) then
    insert into public.owner_flow_ticks (email, step, done_at, done_by)
    values (lower(p_email), p_step, now(), coalesce(public.chat_team_name(), 'Jonathan'))
    on conflict (email) do update
       set step = excluded.step, done_at = now(), done_by = excluded.done_by;
  else
    delete from public.owner_flow_ticks where email = lower(p_email);
  end if;
  return jsonb_build_object('email', lower(p_email), 'done', coalesce(p_done, true));
end $$;

-- One entry per real owner. The path is the list of boxes the owner
-- passed through on the map, in order, in the screen's own names:
--   web | out  -> claim -> (noclaim -> followup -> lost)
--   claimed -> loginnow | nologin -> remind -> (never -> lost | waiting | cc)
--   cc -> left -> dormant | updated -> review -> approved | declined
--   approved -> premium | active | dormant
create or replace function public.admin_owner_flow()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_owners jsonb;
  v_visitors int;
  v_visitors_30 int;
  v_review jsonb;
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;

  select count(distinct seed), count(distinct seed) filter (where created_at > now() - interval '30 days')
    into v_visitors, v_visitors_30
    from public.claim_visits;

  select jsonb_build_object(
      'avg_hours', round(coalesce(avg(extract(epoch from (reviewed_at - submitted_at)) / 3600), 0)::numeric, 1),
      'max_hours', round(coalesce(max(extract(epoch from (reviewed_at - submitted_at)) / 3600), 0)::numeric, 1),
      'reviewed',  count(*),
      'within_24h', count(*) filter (where reviewed_at - submitted_at <= interval '24 hours'))
    into v_review
    from public.owner_drafts
   where reviewed_at is not null and submitted_at is not null
     and lower(owner_email) not in (select email from public.owner_flow_team_emails)
     and lower(owner_email) not like '%nomadwise%';

  with o as (
    select lower(lc.owner_email) as email,
           max(lc.owner_name) as owner_name,
           max(coalesce(nullif(v.name, ''), lc.space_name)) as space_name,
           max(coalesce(nullif(lc.space_city, ''), v.city)) as city,
           max(lc.space_country) as country,
           max(coalesce(v.type, lc.space_type)) as vtype,
           max(v.webflow_slug) as slug,
           bool_or(lc.status in ('free', 'paid')) as claimed,
           min(lc.created_at) as first_claim,
           bool_or(v.listing_tier = 'verified' and exists (
              select 1 from public.stripe_subscriptions s
               where s.subscription_id = v.stripe_subscription_id
                 and s.status in ('active', 'trialing', 'past_due'))) as premium
      from public.listing_claims lc
      left join public.venues v on v.id = lc.venue_id
     where lc.owner_email is not null
       and lower(lc.owner_email) not in (select email from public.owner_flow_team_emails)
       and lower(lc.owner_email) not like '%nomadwise%'
       and coalesce(lc.owner_name, '') not ilike '%test%'
     group by 1
  ), d as (
    select o.*,
      exists (select 1 from public.space_contacts sc
               where lower(sc.email) = o.email and sc.last_out_at is not null
                 and sc.last_out_at < o.first_claim) as via_outreach,
      (select count(distinct day) from public.owner_visits ov where lower(ov.owner_email) = o.email) as login_days,
      (select max(last_at) from public.owner_visits ov where lower(ov.owner_email) = o.email) as last_login,
      (select count(*) from public.sequence_sends ss where lower(ss.owner_email) = o.email) as reminders,
      (select min(sent_at) from public.sequence_sends ss where lower(ss.owner_email) = o.email) as first_reminder,
      (select count(*) from public.owner_drafts od where lower(od.owner_email) = o.email and od.status = 'applied') as applied,
      (select count(*) from public.owner_drafts od where lower(od.owner_email) = o.email and od.status = 'declined') as declined,
      (select count(*) from public.owner_drafts od where lower(od.owner_email) = o.email and od.status = 'draft') as unsent,
      (select max(od.reviewed_at) from public.owner_drafts od where lower(od.owner_email) = o.email) as last_review,
      (select count(distinct day) from public.owner_visits ov
        where lower(ov.owner_email) = o.email
          and ov.first_at > coalesce((select max(od.reviewed_at) from public.owner_drafts od where lower(od.owner_email) = o.email), 'infinity'::timestamptz)) as days_after_review,
      (select jsonb_build_object('step', t.step, 'at', t.done_at, 'by', t.done_by)
         from public.owner_flow_ticks t where t.email = o.email) as tick
    from o
  ), d2 as (
    -- an edit sent from the email link counts as being in the owner account
    select d.*, (d.login_days > 0 or d.applied + d.declined + d.unsent > 0) as logged_in from d
  ), p as (
    select d.*,
      -- the boxes, in order
      (case when d.via_outreach then '["out"' else '["web"' end)
      || ',"claim"'
      || (case when not d.claimed then ',"noclaim","followup","lost"]'
          else ',"claimed"'
            || (case
                 when d.logged_in and (d.first_reminder is null or coalesce(d.last_login, d.last_review) < d.first_reminder) then ',"loginnow","cc"'
                 when d.logged_in then ',"nologin","remind","cc"'
                 when d.reminders >= 2 then ',"nologin","remind","never","lost"]'
                 else ',"nologin","remind","waiting"]'
               end)
            || (case when not d.logged_in then ''
                 when d.applied + d.declined = 0 then ',"left","dormant"]'
                 when d.applied = 0 then ',"updated","review","declined","dormant"]'
                 when d.premium then ',"updated","review","approved","premium"]'
                 when d.days_after_review > 0 then ',"updated","review","approved","active"]'
                 else ',"updated","review","approved","dormant"]'
               end)
          end) as path_text
    from d2 d
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'email', p.email,
           'who', p.owner_name,
           'space', p.space_name,
           'city', nullif(concat_ws(', ', p.city, p.country), ''),
           'type', case when p.vtype = 'cafe' then 'cafe' else 'cowork' end,
           'src', case when p.via_outreach then 'out' else 'web' end,
           'slug', p.slug,
           'claimed_at', p.first_claim,
           'last_login', p.last_login,
           'login_days', p.login_days,
           'reminders', p.reminders,
           'applied', p.applied,
           'declined', p.declined,
           'unsent', p.unsent,
           'last_review', p.last_review,
           'days_after_review', p.days_after_review,
           'premium', p.premium,
           'tick', p.tick,
           'path', p.path_text::jsonb
         ) order by p.first_claim), '[]'::jsonb)
    into v_owners
    from p;

  return jsonb_build_object(
    'owners', v_owners,
    'visitors', v_visitors,
    'visitors_30d', v_visitors_30,
    'review', v_review,
    'since', (select min(created_at) from public.claim_visits),
    'as_of', now());
end $$;

grant execute on function public.admin_owner_flow() to authenticated;
grant execute on function public.admin_owner_flow_tick(text, boolean, text) to authenticated;
