-- ============================================================
-- Migration 283: what owners do in their Owner account, and what
-- they tell us they were looking for.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 7 Nov 2026: "learn exactly what each space does whenever
-- they log in ... what works and what isn't ... an upwards cycle of
-- making Nomadwise better and better for them".
--
--   owner_sessions  one row per visit: device, screen width, where
--                   they came from, first and last moment
--   owner_activity  each step in a visit: tabs opened (and how long),
--                   parts started, saved or left, buttons pressed
--   owner_wishes    "Looking for something?": what an owner typed, in
--                   their own words, with where they were and the steps
--                   just before. We answer each one (planned, done, not
--                   now) and a done one shows up in their account:
--                   "You asked for this. It's here now."
--
--   owner_track(...)         the app sends a visit's steps in batches
--   owner_wish_send(...)     an owner sends what they were looking for
--   owner_wish_news()        done wishes they have not seen yet
--   owner_wish_seen(id)      they closed that note
--   admin_owner_activity(d)  the control centre's Owner activity view
--   admin_owner_timeline(email, d)  one owner's visits, step by step
--   admin_owner_wish_update(...)    our answer to a wish
--
-- Our own visits (team emails) are kept but marked team, and the view
-- hides them unless asked.
-- ============================================================

create table if not exists public.owner_sessions (
  id          uuid primary key,
  owner_email text not null,
  venue_id    uuid,
  team        boolean not null default false,
  started_at  timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  device      text,
  width       int,
  came_from   text,
  spaces      int,
  steps       int not null default 0
);
create index if not exists idx_owner_sessions_email on public.owner_sessions(owner_email, started_at desc);
create index if not exists idx_owner_sessions_started on public.owner_sessions(started_at desc);

create table if not exists public.owner_activity (
  id          bigserial primary key,
  session_id  uuid not null,
  owner_email text not null,
  venue_id    uuid,
  at          timestamptz not null default now(),
  kind        text not null,
  detail      jsonb not null default '{}'::jsonb
);
create index if not exists idx_owner_activity_session on public.owner_activity(session_id, at);
create index if not exists idx_owner_activity_at on public.owner_activity(at desc);
create index if not exists idx_owner_activity_email on public.owner_activity(owner_email, at desc);

create table if not exists public.owner_wishes (
  id            uuid primary key default gen_random_uuid(),
  owner_email   text not null,
  venue_id      uuid,
  session_id    uuid,
  text          text not null,
  trigger       text,
  tab           text,
  trail         jsonb not null default '[]'::jsonb,
  status        text not null default 'new',
  reply         text,
  replied_at    timestamptz,
  owner_seen_at timestamptz,
  owner_seen_status text,
  team          boolean not null default false,
  created_at    timestamptz not null default now()
);
-- (added 8 Nov: which answer they last saw, planned or done)
alter table public.owner_wishes add column if not exists owner_seen_status text;
create index if not exists idx_owner_wishes_created on public.owner_wishes(created_at desc);

alter table public.owner_sessions enable row level security;
alter table public.owner_activity enable row level security;
alter table public.owner_wishes   enable row level security;
-- No policies: everything goes through the functions below.

-- ------------------------------------------------------------------
-- The app sends a visit's steps. p_meta (first call of a visit):
-- device, width, came_from, spaces, venue. p_events: [{kind, detail,
-- ago_ms, venue}] where ago_ms is how long ago it happened on their
-- device, so their clock does not matter. Returns ask_ok: whether we
-- may ask "Looking for something?" (not asked in the last 14 days,
-- and fewer than 2 wishes sent in that time).
-- ------------------------------------------------------------------
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
  return jsonb_build_object('ask_ok', asked is null and sent < 2);
end $$;

-- ------------------------------------------------------------------
create or replace function public.owner_wish_send(p_venue uuid, p_text text, p_context jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  em text := public.owner_email();
  t  text := btrim(coalesce(p_text, ''));
  new_id uuid;
begin
  if em is null then raise exception 'Please sign in.'; end if;
  if length(t) < 2 then raise exception 'Please type a few words.'; end if;
  if not exists (select 1 from public.venues v where v.id = p_venue
                   and lower(btrim(coalesce(v.listing_owner_email, ''))) = em) then
    raise exception 'That space is not on your account.';
  end if;
  insert into public.owner_wishes (owner_email, venue_id, session_id, text, trigger, tab, trail, team)
  values (em, p_venue,
          case when (p_context->>'session') ~ '^[0-9a-f-]{36}$' then (p_context->>'session')::uuid end,
          left(t, 2000),
          left(p_context->>'trigger', 30),
          left(p_context->>'tab', 30),
          coalesce(case when jsonb_typeof(p_context->'trail') = 'array' then p_context->'trail' end, '[]'::jsonb),
          coalesce(public.is_admin(), false))
  returning id into new_id;
  return new_id;
end $$;

-- Answers they have not seen yet, shown once each in their account:
-- Planned ("We're working on this") and Done ("It's here now").
-- Not now stays with us (Jonathan, 8 Nov 2026).
create or replace function public.owner_wish_news()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'text', w.text, 'reply', w.reply,
                                               'status', w.status,
                                               'venue_id', w.venue_id, 'at', w.replied_at)
                            order by w.replied_at), '[]'::jsonb)
    from public.owner_wishes w
   where w.owner_email = public.owner_email()
     and w.status in ('planned', 'done')
     and w.owner_seen_status is distinct from w.status;
$$;

create or replace function public.owner_wish_seen(p_id uuid)
returns void
language sql
volatile
security definer
set search_path to 'public'
as $$
  update public.owner_wishes set owner_seen_at = now(), owner_seen_status = status
   where id = p_id and owner_email = public.owner_email();
$$;

-- ------------------------------------------------------------------
-- Control centre: everything for the Owner activity view, for the
-- last p_days days.
-- ------------------------------------------------------------------
create or replace function public.admin_owner_activity(p_days int, p_team boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  since timestamptz := now() - make_interval(days => greatest(coalesce(p_days, 30), 1));
  res jsonb;
begin
  if not public.is_admin() then raise exception 'Team only.'; end if;
  with s as (
    select * from public.owner_sessions
     where started_at > since and (p_team or not team)
  ), a as (
    select a.* from public.owner_activity a join s on s.id = a.session_id
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
    'minutes', (select coalesce(round(sum(extract(epoch from (last_at - started_at))) / 60.0), 0) from s),
    'median_secs', (select coalesce(percentile_cont(0.5) within group (order by extract(epoch from (last_at - started_at))), 0) from s),
    'phone_share', (select coalesce(round(100.0 * count(*) filter (where device = 'phone') / nullif(count(*), 0)), 0) from s),
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
    'people', (select coalesce(jsonb_agg(p order by (p->>'last_at') desc nulls last, p->>'email'), '[]'::jsonb) from (
              select jsonb_build_object('email', o.em, 'spaces', o.spaces,
                       'sessions', (select count(*) from s where s.owner_email = o.em),
                       'secs', (select coalesce(round(sum(extract(epoch from (last_at - started_at)))), 0) from s where s.owner_email = o.em),
                       'steps', (select coalesce(sum(steps), 0) from s where s.owner_email = o.em),
                       'last_at', (select max(last_at) from public.owner_sessions x where x.owner_email = o.em and (p_team or not x.team)),
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
end $$;

-- One owner's visits, newest first, each with its steps in order.
create or replace function public.admin_owner_timeline(p_email text, p_days int)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'Team only.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id, 'started_at', s.started_at, 'last_at', s.last_at,
             'device', s.device, 'width', s.width, 'came_from', s.came_from, 'team', s.team,
             'steps', (select coalesce(jsonb_agg(jsonb_build_object(
                                'at', a.at, 'kind', a.kind, 'detail', a.detail,
                                'space', (select v.name from public.venues v where v.id = a.venue_id))
                              order by a.at, a.id), '[]'::jsonb)
                         from public.owner_activity a where a.session_id = s.id))
           order by s.started_at desc)
      from public.owner_sessions s
     where s.owner_email = lower(btrim(p_email))
       and s.started_at > now() - make_interval(days => greatest(coalesce(p_days, 30), 1))), '[]'::jsonb);
end $$;

-- Our answer: status new | planned | done | not_now, and a reply.
-- Planned and Done show in their account once each; Done needs a reply
-- so they know where to find it.
create or replace function public.admin_owner_wish_update(p_id uuid, p_status text, p_reply text)
returns void
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'Team only.'; end if;
  if p_status not in ('new', 'planned', 'done', 'not_now') then raise exception 'Unknown status.'; end if;
  if p_status = 'done' and btrim(coalesce(p_reply, '')) = '' then
    raise exception 'Add a reply first, so they know where to find it.';
  end if;
  update public.owner_wishes
     set status = p_status,
         reply = nullif(btrim(coalesce(p_reply, '')), ''),
         replied_at = case when p_status in ('planned', 'done', 'not_now') then now() else replied_at end
   where id = p_id;
end $$;

-- The number beside Owner activity in the control centre menu: owner
-- requests nobody has answered yet (Jonathan, 8 Nov 2026).
create or replace function public.admin_owner_wishes_new()
returns int
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then return 0; end if;
  return (select count(*) from public.owner_wishes where status = 'new' and not team);
end $$;

revoke all on function public.admin_owner_wishes_new() from public, anon;
grant execute on function public.admin_owner_wishes_new() to authenticated;
revoke all on function public.owner_track(uuid, jsonb, jsonb) from public, anon;
revoke all on function public.owner_wish_send(uuid, text, jsonb) from public, anon;
revoke all on function public.owner_wish_news() from public, anon;
revoke all on function public.owner_wish_seen(uuid) from public, anon;
revoke all on function public.admin_owner_activity(int, boolean) from public, anon;
revoke all on function public.admin_owner_timeline(text, int) from public, anon;
revoke all on function public.admin_owner_wish_update(uuid, text, text) from public, anon;
grant execute on function public.owner_track(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.owner_wish_send(uuid, text, jsonb) to authenticated;
grant execute on function public.owner_wish_news() to authenticated;
grant execute on function public.owner_wish_seen(uuid) to authenticated;
grant execute on function public.admin_owner_activity(int, boolean) to authenticated;
grant execute on function public.admin_owner_timeline(text, int) to authenticated;
grant execute on function public.admin_owner_wish_update(uuid, text, text) to authenticated;
