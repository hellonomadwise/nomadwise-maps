-- Migration 152: the coworking numbers, once a day, for the HQ.
--
-- Jonathan, 6 Oct 2026: the HQ page (his private office of figures)
-- could not show the coworking counts by itself, because they live in
-- this database and nothing outside can read it. "Yes build the daily
-- coworking counts so the hq reads."
--
-- Once a day the database counts what the control centre shows
-- (candidates waiting, the steps of Outreach, owners, the Money card,
-- closed places, pages live) and posts those numbers to PostHog, where
-- the site's and the map's analytics already go, as one event named
-- "hq_coworking_counts". The HQ's refresh reads the latest one.
--
-- Numbers only: no name, no address, no email leaves the database.
-- The PostHog key below is the map's public, write-only key (the same
-- one the app carries in the browser), not a secret.
--
-- The counts are the screens' own: the functions behind Candidates,
-- Outreach and the Money card are called, so the HQ and the control
-- centre cannot disagree. Those functions answer admins only, so for
-- the length of the count the job speaks as the first admin on record.
-- It reads; it writes nothing but the one post.

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ------------------------------------------------ the counts
create or replace function public.hq_counts()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o     jsonb := '{}'::jsonb;
  adm   uuid;
  was   text := current_setting('request.jwt.claim.sub', true);
  j     jsonb;
  r     record;
begin
  -- Speak as an admin while counting (see the note at the top), and
  -- give the voice back at the end, whatever happens in between.
  select p.id into adm from public.profiles p where p.is_admin order by p.id limit 1;
  if adm is not null then
    perform set_config('request.jwt.claim.sub', adm::text, true);
  end if;

  -- Candidates: waiting for a yes or no, found but reviews not read
  -- yet, the biggest cities, and the decisions so far.
  begin
    j := public.admin_candidates(null, 1, 0, 'best');
    o := o || jsonb_build_object(
      'cand_waiting', coalesce((j ->> 'total')::int, 0),
      'cand_unread',  coalesce((j ->> 'waiting_scan')::int, 0),
      'cand_london',  coalesce((select (a ->> 'n')::int
                                  from jsonb_array_elements(j -> 'areas') a
                                 where a ->> 'area' = 'London' limit 1), 0));
  exception when others then
    -- (a flag, not the message: only numbers leave the database)
    o := o || jsonb_build_object('cand_error', 1);
  end;
  begin
    select o || jsonb_build_object(
             'cand_turned_down', count(*) filter (where d.decision = 'dismissed'),
             'cand_queued',      count(*) filter (where d.decision = 'queued'))
      into o
      from public.candidate_decisions d;
  exception when others then null;
  end;

  -- Outreach: the two halves of "The path".
  begin
    j := public.admin_outreach_path();
    for r in select key, value from jsonb_each(j -> 'reach')
              where jsonb_typeof(value) = 'number' loop
      o := o || jsonb_build_object('out_' || r.key, r.value);
    end loop;
    for r in select key, value from jsonb_each(j -> 'owners')
              where jsonb_typeof(value) = 'number' loop
      o := o || jsonb_build_object('own_' || r.key, r.value);
    end loop;
    o := o || jsonb_build_object('out_tests', coalesce((j ->> 'tests')::int, 0));
  exception when others then
    -- (a flag, not the message: only numbers leave the database)
    o := o || jsonb_build_object('out_error', 1);
  end;

  -- The Money card: every plain number on it.
  begin
    j := public.admin_money();
    for r in select key, value from jsonb_each(j)
              where jsonb_typeof(value) = 'number' loop
      o := o || jsonb_build_object('money_' || r.key, r.value);
    end loop;
  exception when others then
    -- (a flag, not the message: only numbers leave the database)
    o := o || jsonb_build_object('money_error', 1);
  end;

  -- Closed places still to retire (the control centre's "closed"
  -- group: Google says closed and the page is still up, or the page
  -- is retired and the last two steps are still to do).
  begin
    select o || jsonb_build_object('closed_to_retire', count(*))
      into o
      from public.venues v
     where (v.closed_seen_at is not null and v.closed_dismissed_at is null
            and v.website_retired_at is null
            and v.website_status in ('published_hidden', 'released'))
        or (v.website_retired_at is not null and v.website_retire_done_at is null);
  exception when others then null;
  end;

  -- Pages live on the site, and spaces in the queue.
  begin
    select o || jsonb_build_object(
             'pages_live',           count(*) filter (where v.website_status = 'released'),
             'pages_live_coworking', count(*) filter (where v.website_status = 'released'
                                                        and v.type = 'coworking'),
             'pages_live_cafe',      count(*) filter (where v.website_status = 'released'
                                                        and v.type = 'cafe'),
             'pages_queued',         count(*) filter (where v.website_status = 'queued'))
      into o
      from public.venues v;
  exception when others then null;
  end;

  perform set_config('request.jwt.claim.sub', coalesce(was, ''), true);
  return o;
exception when others then
  perform set_config('request.jwt.claim.sub', coalesce(was, ''), true);
  raise;
end $$;
revoke all on function public.hq_counts() from public, anon, authenticated;
grant execute on function public.hq_counts() to service_role;

-- ------------------------------------------------ the post
create or replace function public.hq_post_counts()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c jsonb;
begin
  c := public.hq_counts();
  perform net.http_post(
    url := 'https://eu.i.posthog.com/capture/',
    body := jsonb_build_object(
      'api_key', 'phc_vZcv4FbDKex8tyKq85MRHd6SgFbEzQoBJpQmvdWY6K4',
      'event', 'hq_coworking_counts',
      'distinct_id', 'nomadmaps-hq-feed',
      'timestamp', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'properties', c || jsonb_build_object(
        'app', 'nomadwise-maps',
        'day', to_char(now() at time zone 'utc', 'YYYY-MM-DD'),
        -- a count, not a person: no profile is made for it
        '$process_person_profile', false)),
    headers := jsonb_build_object('Content-Type', 'application/json'));
  return c;
end $$;
revoke all on function public.hq_post_counts() from public, anon, authenticated;
grant execute on function public.hq_post_counts() to service_role;

-- ------------------------------------------------ every day
-- 05:15 UTC: after the nightly job, before the Monday figures are read.
do $$
begin
  perform cron.unschedule('hq-coworking-counts');
exception when others then null;
end $$;
select cron.schedule('hq-coworking-counts', '15 5 * * *',
  'select public.hq_post_counts()');

-- The first one now, so the HQ has numbers today. Never stops the
-- migration: if the post cannot be made, tomorrow's will be.
do $$
begin
  perform public.hq_post_counts();
exception when others then
  raise warning 'hq_post_counts: %', sqlerrm;
end $$;
