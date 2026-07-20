-- ============================================================
-- Nomadwise Maps — migration 27: visit summary pings
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- (Needs migrations 25 and 26 in first.)
--
-- Ten minutes after a visitor goes quiet, the phone gets a
-- follow-up: "Visitor 735611 finished a visit — viewed 3 spaces
-- (Cafe A, Cafe B) · searched 1 area · 12 actions".
-- One-action bounces are skipped (the arrival ping covered them);
-- team devices never ping. Checks run every 5 minutes.
-- ============================================================

create extension if not exists pg_cron;

-- Remembers how far each visitor's story has been summarized,
-- so no visit is ever reported twice.
create table if not exists public.visitor_summaries (
  anon_id            text primary key,
  last_summarized_at timestamptz not null
);

alter table public.visitor_summaries enable row level security;

create or replace function public.summarize_quiet_visitors()
returns void language plpgsql security definer set search_path = public as $$
declare
  v record;
  opens int; views int; searches int; subs int; total int;
  venues text;
  who text;
  msg text;
begin
  for v in
    select e.anon_id,
           max(e.created_at) as last_event,
           coalesce(s.last_summarized_at,
                    '1970-01-01'::timestamptz) as since
      from public.app_events e
      left join public.visitor_summaries s on s.anon_id = e.anon_id
     where e.created_at > now() - interval '2 hours'
       and not exists (select 1 from public.team_devices td
                        where td.anon_id = e.anon_id)
     group by e.anon_id, s.last_summarized_at
    having max(e.created_at) < now() - interval '10 minutes'
       and max(e.created_at) > coalesce(s.last_summarized_at,
                                        '1970-01-01'::timestamptz)
  loop
    -- Whatever happens next, mark this visit as handled first,
    -- so a failure can never cause repeated pings.
    insert into public.visitor_summaries (anon_id, last_summarized_at)
    values (v.anon_id, v.last_event)
    on conflict (anon_id)
    do update set last_summarized_at = excluded.last_summarized_at;

    -- Team accounts never ping, even before the device is learned.
    if exists (select 1 from public.app_events e
                where e.anon_id = v.anon_id
                  and e.created_at > v.since
                  and public.is_team_member(e.user_id)) then
      continue;
    end if;

    select count(*) filter (where name = 'app_opened'),
           count(*) filter (where name = 'venue_viewed'),
           count(*) filter (where name = 'area_searched'),
           count(*) filter (where name = 'submission_sent'),
           count(*)
      into opens, views, searches, subs, total
      from public.app_events
     where anon_id = v.anon_id
       and created_at > v.since
       and created_at > now() - interval '2 hours';

    -- A single lonely action is a bounce; the arrival ping said it all.
    if total < 2 then continue; end if;

    select string_agg(nm, ', ') into venues
      from (select distinct props->>'venue' as nm
              from public.app_events
             where anon_id = v.anon_id
               and name = 'venue_viewed'
               and created_at > v.since
               and props->>'venue' is not null
             limit 3) t;

    select nullif(p.display_name, '') into who
      from public.app_events e
      join public.profiles p on p.id = e.user_id
     where e.anon_id = v.anon_id and e.user_id is not null
     order by e.created_at desc
     limit 1;

    msg := concat_ws(' · ',
      case when views > 0 then
        'viewed ' || views || ' space' ||
        case when views = 1 then '' else 's' end ||
        coalesce(' (' || venues || ')', '') end,
      case when searches > 0 then
        'searched ' || searches || ' area' ||
        case when searches = 1 then '' else 's' end end,
      case when subs > 0 then
        subs || ' submission' ||
        case when subs = 1 then '' else 's' end end);
    if msg is null or msg = '' then
      msg := total || ' actions';
    else
      msg := msg || ' · ' || total || ' actions';
    end if;

    perform public.notify_phone(
      coalesce(who, 'Visitor ' || right(v.anon_id, 6))
        || ' finished a visit',
      msg,
      'memo');
  end loop;
exception when others then
  null; -- summaries are best-effort, never break anything
end $$;

-- Run the check every 5 minutes.
do $$ begin
  perform cron.unschedule('summarize-visitors');
exception when others then null; end $$;
select cron.schedule('summarize-visitors', '*/5 * * * *',
  'select public.summarize_quiet_visitors()');
