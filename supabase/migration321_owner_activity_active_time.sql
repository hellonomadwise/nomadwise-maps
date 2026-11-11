-- ============================================================
-- Migration 321: Owner activity counts the time an owner was doing
-- something, not the time the page sat open (Jonathan, 11 Nov 2026).
--
-- "Time in accounts" read 2,287 min for 11 visits. Two of them were a
-- tab left open overnight (1,376 and 864 min); the other nine came to
-- 47 min. A visit's length was last_at - started_at, and last_at moves
-- every time the open page checks in.
--
-- Now a visit's length is the time between its steps, where a gap of
-- more than five minutes counts as five: an owner reading for a few
-- minutes still counts, a tab forgotten overnight does not. Same rule
-- for the total, the typical visit and each owner's own time.
--
-- Also for the list of owners, so "last never" is not all we can say
-- of somebody who claimed today:
--   approved_at     when their claim was approved
--   signed_in_at    when they last signed in at all
--   tracking_since  the first visit ever recorded (8 Nov 2026), so the
--                   screen can say why 7, 30 and 90 days look the same
--                   and not promise anything from before it.
-- A visit is only recorded once the listing is theirs (owner_track), so
-- an owner who signs in while the claim waits for us shows no visit.
-- ============================================================

create or replace function public.admin_owner_activity(p_days integer, p_team boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  since timestamptz := now() - make_interval(days => greatest(coalesce(p_days, 30), 1));
  res jsonb;
begin
  if not public.is_admin() then raise exception 'Team only.'; end if;
  with s0 as (
    select * from public.owner_sessions
     where started_at > since and (p_team or not team)
  ), a as (
    select a.* from public.owner_activity a join s0 on s0.id = a.session_id
  ), gaps as (
    -- every step of a visit, with the visit's start as the first one
    select session_id, at, lag(at) over (partition by session_id order by at) prev
      from (select id session_id, started_at at from s0
            union all
            select session_id, at from a) p
  ), act as (
    select session_id, sum(least(extract(epoch from (at - prev)), 300)) secs
      from gaps where prev is not null group by session_id
  ), s as (
    select s0.*, coalesce(act.secs, 0)::numeric active_secs
      from s0 left join act on act.session_id = s0.id
  ), owners as (
    select lower(btrim(v.listing_owner_email)) em,
           jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name) order by v.name) spaces
      from public.venues v
     where coalesce(btrim(v.listing_owner_email), '') <> ''
     group by 1
  )
  select jsonb_build_object(
    'owners_total', (select count(*) from owners),
    'owners_active', (select count(distinct owner_email) from s),
    'sessions', (select count(*) from s),
    'minutes', (select coalesce(round(sum(active_secs) / 60.0), 0) from s),
    'median_secs', (select coalesce(percentile_cont(0.5) within group (order by active_secs), 0) from s),
    'phone_share', (select coalesce(round(100.0 * count(*) filter (where device = 'phone') / nullif(count(*), 0)), 0) from s),
    'tracking_since', (select min(started_at) from public.owner_sessions),
    -- Tabs: how many owners opened each, how often, and the time spent.
    'tabs', (select coalesce(jsonb_agg(t order by (t->>'owners')::int desc), '[]'::jsonb) from (
              select jsonb_build_object('tab', tab,
                       'owners', count(distinct owner_email) filter (where k = 'open'),
                       'opens', count(*) filter (where k = 'open'),
                       'secs', coalesce(round(sum(secs)), 0)) t
                from (select detail->>'to' tab, owner_email, 'open' k, null::numeric secs
                        from a where kind = 'tab'
                      union all
                      select detail->>'from', owner_email, 'leave', least((detail->>'secs')::numeric, 1800)
                        from a where kind in ('tab', 'leave') and detail ? 'from' and detail ? 'secs') u
               where tab is not null
               group by tab) q),
    -- Parts of My listing: started, saved, left without saving.
    'edits', (select coalesce(jsonb_agg(e order by (e->>'started')::int desc), '[]'::jsonb) from (
              select jsonb_build_object('part', detail->>'part',
                       'owners', count(distinct owner_email),
                       'started', count(*) filter (where kind = 'edit_start'),
                       'saved', count(*) filter (where kind = 'edit_save'),
                       'left', count(*) filter (where kind = 'edit_cancel')) e
                from a where kind in ('edit_start', 'edit_save', 'edit_cancel') and detail ? 'part'
               group by detail->>'part') q),
    -- Everything else they pressed.
    'actions', (select coalesce(jsonb_agg(c order by (c->>'times')::int desc), '[]'::jsonb) from (
              select jsonb_build_object('kind', kind, 'owners', count(distinct owner_email), 'times', count(*)) c
                from a where kind not in ('tab', 'leave', 'edit_start', 'edit_save', 'edit_cancel', 'session_start')
               group by kind) q),
    -- One row per owner with spaces, active or not.
    'people', (select coalesce(jsonb_agg(p order by (p->>'last_at') desc nulls last,
                                                    (p->>'approved_at') desc nulls last, p->>'email'), '[]'::jsonb) from (
              select jsonb_build_object('email', o.em, 'spaces', o.spaces,
                       'sessions', (select count(*) from s where s.owner_email = o.em),
                       'secs', (select coalesce(round(sum(active_secs)), 0) from s where s.owner_email = o.em),
                       'steps', (select coalesce(sum(steps), 0) from s where s.owner_email = o.em),
                       'last_at', (select max(last_at) from public.owner_sessions x where x.owner_email = o.em and (p_team or not x.team)),
                       'approved_at', (select max(c.approved_at) from public.listing_claims c
                                        where lower(btrim(c.owner_email)) = o.em),
                       'signed_in_at', (select max(u.last_sign_in_at) from auth.users u where lower(u.email) = o.em),
                       'tabs', (select coalesce(jsonb_agg(distinct a.detail->>'to'), '[]'::jsonb) from a where a.owner_email = o.em and a.kind = 'tab'),
                       'saves', (select count(*) from a where a.owner_email = o.em and a.kind = 'edit_save'),
                       'wishes', (select count(*) from public.owner_wishes w where w.owner_email = o.em)) p
                from owners o) q),
    'wishes', (select coalesce(jsonb_agg(jsonb_build_object(
                       'id', w.id, 'email', w.owner_email, 'venue_id', w.venue_id,
                       'space', (select v.name from public.venues v where v.id = w.venue_id),
                       'text', w.text, 'trigger', w.trigger, 'tab', w.tab, 'trail', w.trail,
                       'status', w.status, 'reply', w.reply, 'replied_at', w.replied_at,
                       'owner_seen_at', w.owner_seen_at, 'owner_seen_status', w.owner_seen_status,
                       'created_at', w.created_at)
                     order by (w.status = 'new') desc, w.created_at desc), '[]'::jsonb)
                 from public.owner_wishes w where p_team or not w.team)
  ) into res;
  return res;
end $function$;

revoke all on function public.admin_owner_activity(int, boolean) from public, anon;
grant execute on function public.admin_owner_activity(int, boolean) to authenticated;
