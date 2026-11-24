-- ============================================================
-- Migration 355: three things from the first owner-behaviour read
-- (Jonathan, 24 Nov 2026: "Yes. Build all").
--
-- 1. My listing shows one Performance number with a way to the
--    Performance tab. App only: it uses owner_locations (migration 281).
-- 2. "Short on time?": an owner who has never saved a change is offered
--    to tell us what has changed, and we put it on their page (the
--    done-for-you service, 20 Nov 2026). owner_track now also answers
--    help_offer (may we offer it) and been_before (have they been in
--    before this visit). What they type is an owner_wishes row with
--    trigger 'do_it_for_me'. Closing it (help_dismissed) or using it
--    puts it away for 30 days.
-- 3. Owner activity says what kind of owner each one is, from
--    everything recorded: hands_on (has saved a change), looker (has
--    been in, changed nothing), not_in (never been in).
-- 4. A request an owner sends ("Looking for something?" or "Short on
--    time?") joins the Waiting on us watch after 3 hours.
-- ============================================================

create index if not exists owner_activity_owner_kind
  on public.owner_activity (owner_email, kind);

create or replace function public.owner_track(p_session uuid, p_meta jsonb, p_events jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  em    text := public.owner_email();
  is_team boolean;
  mine  uuid[];
  n     int := 0;
  asked timestamptz;
  sent  int;
  help  boolean;
  been  boolean;
begin
  if em is null or p_session is null then return jsonb_build_object('ask_ok', false); end if;
  is_team := coalesce(public.is_admin(), false);
  select coalesce(array_agg(v.id), '{}') into mine
    from public.venues v where lower(btrim(coalesce(v.listing_owner_email, ''))) = em;
  if cardinality(mine) = 0 then return jsonb_build_object('ask_ok', false); end if;

  insert into public.owner_sessions as s (id, owner_email, venue_id, team, device, width, came_from, spaces)
  values (p_session, em,
          case when (p_meta->>'venue') ~ '^[0-9a-f-]{36}$' and (p_meta->>'venue')::uuid = any(mine)
               then (p_meta->>'venue')::uuid end,
          is_team,
          left(p_meta->>'device', 20),
          nullif(p_meta->>'width', '')::int,
          left(p_meta->>'came_from', 120),
          nullif(p_meta->>'spaces', '')::int)
  on conflict (id) do update set last_at = now()
   where s.owner_email = em;

  if jsonb_typeof(p_events) = 'array' then
    insert into public.owner_activity (session_id, owner_email, venue_id, at, kind, detail)
    select p_session, em,
           case when (e->>'venue') ~ '^[0-9a-f-]{36}$' and (e->>'venue')::uuid = any(mine)
                then (e->>'venue')::uuid end,
           now() - make_interval(secs => least(greatest(coalesce((e->>'ago_ms')::numeric, 0), 0), 3600000) / 1000.0),
           left(e->>'kind', 40),
           coalesce(case when jsonb_typeof(e->'detail') = 'object' then e->'detail' end, '{}'::jsonb)
      from (select e from jsonb_array_elements(p_events) e limit 200) x
     where coalesce(e->>'kind', '') <> '';
    get diagnostics n = row_count;
    if n > 0 then
      update public.owner_sessions set steps = steps + n, last_at = now()
       where id = p_session and owner_email = em;
    end if;
  end if;

  select max(a.at) into asked from public.owner_activity a
   where a.owner_email = em and a.kind = 'ask_shown' and a.at > now() - interval '14 days';
  select count(*) into sent from public.owner_wishes w
   where w.owner_email = em and w.created_at > now() - interval '14 days';
  -- "Short on time?" (migration 355): offered to an owner who has never
  -- saved a change, unless they closed it or used it in the last 30 days.
  -- Changes from before visits were recorded (8 Nov 2026) count as saved.
  help := not exists (select 1 from public.owner_activity a
                       where a.owner_email = em and a.kind = 'edit_save')
      and not exists (select 1 from public.venues v
                       where v.id = any(mine) and v.owner_content_at < timestamptz '2026-11-08')
      and not exists (select 1 from public.owner_activity a
                       where a.owner_email = em and a.kind = 'help_dismissed'
                         and a.at > now() - interval '30 days')
      and not exists (select 1 from public.owner_wishes w
                       where w.owner_email = em and w.trigger = 'do_it_for_me'
                         and w.created_at > now() - interval '30 days');
  -- Have they been in before this visit?
  been := exists (select 1 from public.owner_sessions s
                   where s.owner_email = em and s.id <> p_session
                     and s.started_at < now() - interval '30 minutes')
       or exists (select 1 from public.owner_visits ov
                   where lower(ov.owner_email) = em and ov.day < current_date);
  return jsonb_build_object('ask_ok', asked is null and sent < 2,
                            'help_offer', help, 'been_before', been);
end $$;

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
                       'wishes', (select count(*) from public.owner_wishes w where w.owner_email = o.em),
                       -- What kind of owner, from everything recorded, not only
                       -- the period picked (migration 355).
                       'kind', case
                         when exists (select 1 from public.owner_activity x
                                       where x.owner_email = o.em and x.kind = 'edit_save')
                           or exists (select 1 from public.venues v
                                       where lower(btrim(v.listing_owner_email)) = o.em
                                         and v.owner_content_at < timestamptz '2026-11-08')
                           then 'hands_on'
                         when exists (select 1 from public.owner_sessions x
                                       where x.owner_email = o.em and not x.team)
                           or exists (select 1 from public.owner_visits x
                                       where lower(x.owner_email) = o.em)
                           then 'looker'
                         else 'not_in' end) p
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

revoke all on function public.owner_track(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.owner_track(uuid, jsonb, jsonb) to authenticated;
revoke all on function public.admin_owner_activity(int, boolean) from public, anon;
grant execute on function public.admin_owner_activity(int, boolean) to authenticated;

-- ------------------------------------------------------------------
-- What an owner asks for must not wait unnoticed either (migration 334
-- watched everything but this): a request nobody has answered goes to
-- the phone after 3 hours, with the rest of "Waiting on us".
select public.pm_patch_fn('public.waiting_on_us()',
  $a$     and (c.snooze_until is null or c.snooze_until < now());$a$,
  $a$     and (c.snooze_until is null or c.snooze_until < now())
  union all
  select 'Owner asked us', 'wish:' || w.id, coalesce(v.name, 'a space'), w.created_at, 3
    from public.owner_wishes w
    left join public.venues v on v.id = w.venue_id
   where w.status = 'new' and not w.team;$a$,
  $a$'wish:' || w.id$a$);
