-- ============================================================
-- Migration 205: the Owner flow's results by time, not by a box.
--
-- Jonathan, 3 Nov 2026, on an owner who claimed and edited an hour
-- earlier and showed as Dormant: "I'm not sure if we should categorise
-- these as dormant, as it implies that something is wrong ... maybe
-- we should define what dormant means." After approval the result is
-- now by time: New (approved under 14 days ago), Active (seen in the
-- last 30 days), Quiet (30 to 60 days since last seen), Dormant (over
-- 60). "Came back" is now a measure: returned within 30 days of
-- approval (null while too early to tell). Looks-only and Declined
-- owners get the same time rule after their last visit. Claim-page
-- visitors leave out a crawler that arrives from random blog posts
-- and never takes a step. Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.admin_owner_flow(p_as_of timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t timestamptz := coalesce(p_as_of, now());
  v_owners jsonb;
  v_visitors int;
  v_visitors_30 int;
  v_review jsonb;
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;

  -- claim-page visitors: real people, as the Analytics screen counts them
  -- (claim_opened events; team devices and known bots left out). Not
  -- claim_visits, whose seed is the space looked at, not the visitor.
  -- A crawler sweeps the claim page from random blog posts (29 of them
  -- between 22 Oct and 3 Nov, none took a step), so a visit counts only
  -- when it came from somewhere other than a blog post, or the visitor
  -- did something on the page.
  with v as (
    select anon_id, min(created_at) as first_at,
           bool_or(coalesce(props->>'from', '') not like '/blog/%') as not_from_blog
      from public.app_events
     where name = 'claim_opened' and created_at <= t
       and anon_id not in (select anon_id from public.team_devices)
       and anon_id not in (select anon_id from public.bot_visitors)
     group by 1
  ), acted as (
    select distinct anon_id from public.app_events
     where name in ('claim_step', 'claim_typed', 'claim_free', 'claim_to_payment', 'claim_space') and created_at <= t
  )
  select count(*), count(*) filter (where first_at > t - interval '30 days')
    into v_visitors, v_visitors_30
    from v where not_from_blog or anon_id in (select anon_id from acted);

  select jsonb_build_object(
      'avg_hours', round(coalesce(avg(extract(epoch from (reviewed_at - submitted_at)) / 3600), 0)::numeric, 1),
      'max_hours', round(coalesce(max(extract(epoch from (reviewed_at - submitted_at)) / 3600), 0)::numeric, 1),
      'reviewed',  count(*),
      'within_24h', count(*) filter (where reviewed_at - submitted_at <= interval '24 hours'))
    into v_review
    from public.owner_drafts
   where reviewed_at is not null and submitted_at is not null and reviewed_at <= t
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
     where lc.owner_email is not null and lc.created_at <= t
       and lower(lc.owner_email) not in (select email from public.owner_flow_team_emails)
       and lower(lc.owner_email) not like '%nomadwise%'
       and coalesce(lc.owner_name, '') not ilike '%test%'
     group by 1
  ), d as (
    select o.*,
      exists (select 1 from public.space_contacts sc
               where lower(sc.email) = o.email and sc.last_out_at is not null
                 and sc.last_out_at < o.first_claim) as via_outreach,
      (select count(distinct day) from public.owner_visits ov where lower(ov.owner_email) = o.email and ov.first_at <= t) as login_days,
      (select max(least(last_at, t)) from public.owner_visits ov where lower(ov.owner_email) = o.email and ov.first_at <= t) as last_login,
      (select count(*) from public.sequence_sends ss where lower(ss.owner_email) = o.email and ss.sent_at <= t) as reminders,
      (select min(sent_at) from public.sequence_sends ss where lower(ss.owner_email) = o.email and ss.sent_at <= t) as first_reminder,
      (select count(*) from public.owner_drafts od where lower(od.owner_email) = o.email and od.status = 'applied' and od.reviewed_at <= t) as applied,
      (select count(*) from public.owner_drafts od where lower(od.owner_email) = o.email and od.status = 'declined' and od.reviewed_at <= t) as declined,
      (select count(*) from public.owner_drafts od where lower(od.owner_email) = o.email and ((od.status = 'draft' and od.created_at <= t) or (od.status <> 'draft' and od.submitted_at <= t and (od.reviewed_at is null or od.reviewed_at > t)))) as unsent,
      (select max(od.reviewed_at) from public.owner_drafts od where lower(od.owner_email) = o.email and od.reviewed_at <= t) as last_review,
      (select count(distinct day) from public.owner_visits ov
        where lower(ov.owner_email) = o.email and ov.first_at <= t
          and ov.first_at > coalesce((select max(od.reviewed_at) from public.owner_drafts od where lower(od.owner_email) = o.email and od.reviewed_at <= t), 'infinity'::timestamptz)) as days_after_review,
      (select jsonb_build_object('step', tk.step, 'at', tk.done_at, 'by', tk.done_by)
         from public.owner_flow_ticks tk where tk.email = o.email) as tick
    from o
  ), d2 as (
    -- an edit sent from the email link counts as being in the owner account
    select d.*, (d.login_days > 0 or d.applied + d.declined + d.unsent > 0) as logged_in,
      -- the owner's last sign of life: a visit, or an edit submitted
      greatest(d.last_login, (select max(od.submitted_at) from public.owner_drafts od where lower(od.owner_email) = d.email and od.submitted_at <= t)) as last_seen
    from d
  ), d3 as (
    select d2.*,
      extract(epoch from (t - d2.last_review)) / 86400 as days_since_approval,
      extract(epoch from (t - d2.last_seen)) / 86400 as days_quiet,
      -- came back within 30 days of approval (null while too early to tell)
      case when d2.last_review is null then null
           when d2.days_after_review > 0 then true
           when t - d2.last_review >= interval '30 days' then false
           else null end as returned_30
    from d2
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
                 when d.applied + d.declined = 0 then ',"left",' || (case when d.days_quiet < 30 then '"new"]' when d.days_quiet < 60 then '"quiet"]' else '"dormant"]' end)
                 when d.applied = 0 then ',"updated","review","declined",' || (case when d.days_quiet < 30 then '"new"]' when d.days_quiet < 60 then '"quiet"]' else '"dormant"]' end)
                 when d.premium then ',"updated","review","approved","premium"]'
                 -- after approval, by time (Jonathan, 3 Nov 2026): new under
                 -- 14 days since approval; active when seen in the last 30;
                 -- quiet 30 to 60 days since last seen; dormant after 60
                 when d.days_since_approval < 14 then ',"updated","review","approved","new"]'
                 when d.days_quiet < 30 then ',"updated","review","approved","active"]'
                 when d.days_quiet < 60 then ',"updated","review","approved","quiet"]'
                 else ',"updated","review","approved","dormant"]'
               end)
          end) as path_text
    from d3 d
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
           'last_seen', p.last_seen,
           'days_quiet', round(p.days_quiet::numeric, 1),
           'returned_30', p.returned_30,
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
    'since', (select min(created_at) from public.app_events where name = 'claim_opened'),
    'as_of', t);
end $$;

grant execute on function public.admin_owner_flow(timestamptz) to authenticated;
