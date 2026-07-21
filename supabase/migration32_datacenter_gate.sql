-- ============================================================
-- Nomadwise Maps — migration 32: data-centre visitors never ping
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- The app now tags arrivals coming from data-centre addresses
-- (Amazon, Google Cloud, hosting providers) with dc = true.
-- Real homes and cafes never are; VPNs sometimes are. Tagged
-- visitors trigger no arrival pings and no visit summaries.
-- ============================================================

create or replace function public.notify_app_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  who text;
begin
  if new.name = 'app_opened'
     and not public.looks_like_bot(new.props->>'ua')
     and coalesce((new.props->>'dc')::boolean, false) = false
     and not public.is_team_member(new.user_id)
     and not exists (
       select 1 from public.team_devices td
        where td.anon_id = new.anon_id)
     and not exists (
       select 1 from public.app_events e
        where e.anon_id = new.anon_id
          and e.name = 'app_opened'
          and e.id <> new.id
          and e.created_at > now() - interval '6 hours')
  then
    if new.user_id is not null then
      select nullif(display_name, '') into who
        from public.profiles where id = new.user_id;
    end if;
    perform public.notify_phone(
      'Someone is on Nomadmaps',
      coalesce(who, 'Visitor ' || right(new.anon_id, 6))
        || ' opened the app',
      'eyes');
  end if;
  return new;
exception when others then
  return new;
end $$;

-- Visit summaries: skip visitors whose arrival was bot-like or
-- from a data-centre address.
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
       and not exists (select 1 from public.app_events b
                        where b.anon_id = e.anon_id
                          and b.created_at > now() - interval '2 hours'
                          and (public.looks_like_bot(b.props->>'ua')
                               or coalesce((b.props->>'dc')::boolean,
                                           false)))
     group by e.anon_id, s.last_summarized_at
    having max(e.created_at) < now() - interval '10 minutes'
       and max(e.created_at) > coalesce(s.last_summarized_at,
                                        '1970-01-01'::timestamptz)
  loop
    insert into public.visitor_summaries (anon_id, last_summarized_at)
    values (v.anon_id, v.last_event)
    on conflict (anon_id)
    do update set last_summarized_at = excluded.last_summarized_at;

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
  null;
end $$;
