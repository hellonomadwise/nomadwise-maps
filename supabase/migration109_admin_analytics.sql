-- ============================================================
-- Migration 109: the Analytics page counts in the database.
-- (Applied automatically by the build; nothing to paste.)
--
-- Until now the page downloaded at most 2,000 recorded actions and
-- counted them on the phone, so once traffic passed that the numbers
-- quietly stopped adding up. admin_analytics() does the same counting
-- here, over every recorded action, for 7, 30 or 90 days (any number
-- of days up to a year), and counts the period before it too, so each
-- number can show its change.
--
-- The same rules as before decide who counts:
--   * team accounts and every device ever used by one are left out,
--     as are the founders' own email addresses;
--   * automated visitors are left out: a browser identity that looks
--     like a bot, or a data-centre connection that never did anything
--     a person does (people on a VPN prove themselves by acting);
--   * "Friends" shows only devices used by friend accounts;
--   * "Customers" leaves out friend and owner devices.
--
-- New in the same call:
--   * where visitors came from (utm_source, ref, or the site that
--     linked to the app, recorded from today);
--   * the owners' funnel: claim page opened, started the form, claimed
--     free, went to payment, paid;
--   * places people searched for that have few or no spaces near them
--     (recorded from today), which says where to sweep next.
-- admin_visitor_trail() returns one visitor's latest actions, for the
-- visitor list, so the list no longer needs every event downloaded.
-- ============================================================

create or replace function public.admin_analytics(
  p_days    integer default 14,
  p_segment text    default 'all',
  p_tz_min  integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  d      integer := greatest(1, least(coalesce(p_days, 14), 365));
  tz     interval := make_interval(mins => greatest(-900, least(coalesce(p_tz_min, 0), 900)));
  since  timestamptz := now() - make_interval(days => d);
  prev   timestamptz := now() - make_interval(days => 2 * d);
  today  date := ((now() at time zone 'UTC') + make_interval(mins => greatest(-900, least(coalesce(p_tz_min, 0), 900))))::date;
  seg    text := coalesce(p_segment, 'all');
  res    jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;

  with
  ev as (
    select e.anon_id, e.user_id, e.name, coalesce(e.props, '{}'::jsonb) as props,
           e.created_at,
           (e.created_at >= since) as cur,
           ((e.created_at at time zone 'UTC') + tz)::date as day
      from public.app_events e
     where e.created_at >= prev
  ),
  team_users as (
    select p.id from public.profiles p where p.cohort = 'team'
    union
    select u.id from auth.users u
     where lower(u.email) in ('hellonomadwise@gmail.com',
                              'leonie.poelking@googlemail.com',
                              'jonnythebackpacker@gmail.com',
                              'corneliousbeck@gmail.com')
  ),
  human_anon as (
    select distinct anon_id from ev
     where user_id is not null
        or name in ('venue_viewed', 'area_searched', 'global_search_used',
                    'place_searched', 'signed_in', 'submission_sent',
                    'wifi_test_measured', 'space_shared', 'feedback_sent',
                    'coins_converted', 'wallet_viewed', 'leaderboard_viewed')
  ),
  internal_anon as (
    select anon_id from ev where user_id in (select id from team_users)
    union
    select anon_id from public.team_devices
    union
    select anon_id from ev
     where props->>'ua' ~* ('bot|crawl|spider|slurp|headless|lighthouse|phantom|selenium|'
                            'puppeteer|playwright|bingpreview|facebookexternalhit|'
                            'whatsapp|telegram|discord|skype|preview|python|curl|wget|'
                            'monitor|pingdom|uptime|inspection|google-read|feedfetcher')
    union
    (select anon_id from ev where props->>'dc' = 'true'
     except
     select anon_id from human_anon)
  ),
  friend_anon as (
    select anon_id from ev
     where user_id in (select id from public.profiles where cohort = 'friend')
    except select anon_id from internal_anon
  ),
  owner_anon as (
    select anon_id from ev
     where user_id in (select id from public.profiles where cohort = 'owner')
    except select anon_id from internal_anon
  ),
  -- People, not the team or machines (the owners' funnel uses this).
  h as (
    select * from ev where anon_id not in (select anon_id from internal_anon)
  ),
  -- ... and within the chosen audience (everything else uses this).
  f as (
    select * from h
     where case seg
             when 'friends' then anon_id in (select anon_id from friend_anon)
             when 'customers' then anon_id not in (select anon_id from friend_anon)
                               and anon_id not in (select anon_id from owner_anon)
             else true end
  ),
  per as (
    select cur,
           count(distinct anon_id) as visitors,
           count(*) filter (where name = 'app_opened') as opens,
           count(distinct anon_id) filter (where user_id is not null) as signed,
           count(distinct anon_id) filter (where name = 'venue_viewed') as viewed,
           count(distinct anon_id) filter (where name = 'submission_sent') as submitted,
           count(distinct anon_id) filter (where name = 'directions_clicked') as directions,
           count(*) as actions
      from f group by cur
  ),
  ret as (
    select cur, count(*) as back
      from (select cur, anon_id from f group by cur, anon_id
             having count(distinct day) >= 2) x
     group by cur
  ),
  daily as (
    select g.day::date as day,
           (select count(distinct f.anon_id) from f where f.cur and f.day = g.day::date) as n
      from generate_series(today - (d - 1), today, interval '1 day') as g(day)
  ),
  spaces as (
    select props->>'venue' as venue,
           count(*) filter (where name = 'venue_viewed') as views,
           count(*) filter (where name = 'space_shared') as shares,
           count(*) filter (where name = 'directions_clicked') as directions
      from f
     where cur and coalesce(props->>'venue', '') <> ''
     group by 1
  ),
  acts as (
    select name, count(*) as n from f where cur group by name
  ),
  src_raw as (
    select distinct on (cur, anon_id) cur, anon_id,
           lower(coalesce(nullif(props->>'utm_source', ''),
                          nullif(props->>'ref', ''),
                          nullif(props->>'referrer', ''), '')) as raw
      from f
     where name = 'app_opened'
     order by cur, anon_id, created_at
  ),
  src as (
    select cur, anon_id,
           case
             when raw = '' or raw ~ 'nomadmaps' then 'Direct or unknown'
             when raw ~ 'nomadwise' then 'nomadwise.io'
             when raw ~ 'google' then 'Google'
             when raw ~ 'instagram' then 'Instagram'
             when raw ~ 'facebook|(^|\.)fb\.' then 'Facebook'
             when raw ~ 'whatsapp|wa\.me' then 'WhatsApp'
             when raw ~ '(^|\.)t\.co$|twitter|(^|\.)x\.com' then 'X'
             when raw ~ 'linkedin|lnkd' then 'LinkedIn'
             when raw ~ 'reddit' then 'Reddit'
             when raw ~ 'bing' then 'Bing'
             when raw ~ 'duckduckgo' then 'DuckDuckGo'
             when raw ~ 'chatgpt|openai' then 'ChatGPT'
             when raw ~ 'perplexity' then 'Perplexity'
             when raw ~ 'tiktok' then 'TikTok'
             when raw ~ 'youtube' then 'YouTube'
             else regexp_replace(raw, '^www\.', '')
           end as source
      from src_raw
  ),
  sources as (
    select source,
           count(*) filter (where cur) as n,
           count(*) filter (where not cur) as before
      from src group by source
  ),
  vis as (
    select anon_id, max(created_at) as last_at, count(*) as n,
           (array_agg(user_id) filter (where user_id is not null))[1] as uid
      from f where cur
     group by anon_id
     order by max(created_at) desc
     limit 100
  ),
  own as (
    select cur,
           count(distinct anon_id) filter (where name = 'claim_opened') as opened,
           count(distinct anon_id) filter (where name = 'claim_typed') as started,
           count(distinct anon_id) filter (where name = 'claim_free') as free,
           count(distinct anon_id) filter (where name = 'claim_to_payment') as to_payment
      from h group by cur
  ),
  searched as (
    select lower(trim(props->>'query')) as q,
           max(props->>'where') as place_where,
           count(*) as searches,
           min(case when props->>'spaces_near' ~ '^[0-9]+$'
                    then (props->>'spaces_near')::integer end) as near
      from h
     where cur and name = 'place_searched' and coalesce(trim(props->>'query'), '') <> ''
     group by 1
  )
  select jsonb_build_object(
    'days', d,
    'segment', seg,
    'cur', coalesce((select to_jsonb(p) - 'cur' from per p where p.cur), '{}'::jsonb)
           || jsonb_build_object('returning', coalesce((select back from ret where cur), 0)),
    'prev', coalesce((select to_jsonb(p) - 'cur' from per p where not p.cur), '{}'::jsonb)
           || jsonb_build_object('returning', coalesce((select back from ret where not cur), 0)),
    'visitors_24h', (select count(distinct anon_id) from f where created_at >= now() - interval '24 hours'),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'n', n) order by day) from daily), '[]'::jsonb),
    'top_spaces', coalesce((select jsonb_agg(to_jsonb(s) order by s.views desc, s.venue)
                              from (select * from spaces where views > 0 order by views desc, venue limit 8) s), '[]'::jsonb),
    'actions', coalesce((select jsonb_agg(to_jsonb(a) order by a.n desc)
                           from (select * from acts order by n desc limit 10) a), '[]'::jsonb),
    'sources', coalesce((select jsonb_agg(to_jsonb(s) order by s.n desc, s.source)
                           from (select * from sources where n > 0 order by n desc limit 12) s), '[]'::jsonb),
    'visitors', coalesce((select jsonb_agg(jsonb_build_object(
                             'anon', v.anon_id,
                             'last_at', v.last_at,
                             'actions', v.n,
                             'signed', v.uid is not null,
                             'name', pr.display_name,
                             'friend', v.anon_id in (select anon_id from friend_anon))
                           order by v.last_at desc)
                            from vis v left join public.profiles pr on pr.id = v.uid), '[]'::jsonb),
    'owners', jsonb_build_object(
      'cur', coalesce((select to_jsonb(o) - 'cur' from own o where o.cur), '{}'::jsonb)
             || jsonb_build_object('paid', (select count(*) from public.listing_claims c
                                              where c.paid_at >= since)),
      'prev', coalesce((select to_jsonb(o) - 'cur' from own o where not o.cur), '{}'::jsonb)
             || jsonb_build_object('paid', (select count(*) from public.listing_claims c
                                              where c.paid_at >= prev and c.paid_at < since))),
    'searches', coalesce((select jsonb_agg(to_jsonb(s) order by s.searches desc, s.near)
                            from (select * from searched where coalesce(near, 0) <= 2
                                   order by searches desc, near limit 15) s), '[]'::jsonb),
    'excluded', (select count(distinct anon_id) from ev
                  where cur and anon_id in (select anon_id from internal_anon))
  ) into res;

  return res;
end $$;
revoke all on function public.admin_analytics(integer, text, integer) from public, anon;
grant execute on function public.admin_analytics(integer, text, integer) to authenticated;

-- One visitor's latest actions, newest first.
create or replace function public.admin_visitor_trail(p_anon text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('name', e.name, 'props', e.props,
                                        'created_at', e.created_at)
                     order by e.created_at desc)
      from (select * from public.app_events
             where anon_id = p_anon
             order by created_at desc
             limit 80) e), '[]'::jsonb);
end $$;
revoke all on function public.admin_visitor_trail(text) from public, anon;
grant execute on function public.admin_visitor_trail(text) to authenticated;

-- Counting 90 days of actions by device and time stays quick.
create index if not exists idx_app_events_anon_time
  on public.app_events (anon_id, created_at desc);
