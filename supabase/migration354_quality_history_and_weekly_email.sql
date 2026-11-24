-- Migration 354: Quality keeps a count for every day, so Clean-up can
-- show a chart that should fall to zero, and Jonathan gets a weekly
-- email about Quality (Jonathan, 24 Nov 2026: "add a cleanup chart, so
-- i can see visual, like bar chart overtime, similar to google search
-- console indexing, where the goal is to have the bar chart line be
-- zero. so i can see it reducing, and it increases if there's actions
-- to take", then "send jonathan@nomadwise.io weekly email with overview
-- on Quality area, which includes a chart and dashboard summary, in the
-- simplest way possible").
--
-- 1. quality_daily: one row a day with what was waiting in Quality.
-- 2. quality_counts(): what is waiting now, counted exactly as the
--    Quality screens count it.
-- 3. quality_snapshot(): writes today's row; every night at 23:50 UTC.
-- 4. The past, for Closed only, worked out from the dates we hold
--    (when Google first reported the closure, when the page was
--    retired). Marked estimated. No Location and the rest have no past.
-- 5. admin_quality_history(): the rows for the chart, today's live.
-- 6. quality_weekly_send(): the email, Mondays 07:31 UTC, to
--    jonathan@nomadwise.io only.

create table if not exists public.quality_daily (
  day          date primary key,
  closed_temp  integer not null default 0,
  closed_perm  integer not null default 0,
  no_location  integer,
  not_for_site integer,
  suggestions  integer,
  upgrades     integer,
  prices       integer,
  estimated    boolean not null default false,
  taken_at     timestamptz not null default now()
);
comment on table public.quality_daily is
  'What was waiting in Quality at the end of each day (UTC). estimated: worked out afterwards from dates, Closed only.';
alter table public.quality_daily enable row level security;
revoke all on public.quality_daily from anon, authenticated;

create table if not exists public.quality_emails (
  id           bigint generated always as identity primary key,
  sent_at      timestamptz not null default now(),
  to_email     text not null,
  subject      text not null,
  counts       jsonb,
  provider_req text
);
alter table public.quality_emails enable row level security;
revoke all on public.quality_emails from anon, authenticated;

-- What is waiting now. Each count follows the screen it belongs to:
-- Closed as websiteClosed() in the app, No Location as the "to do" of
-- admin_live_without_location() without the ones already on their way,
-- Suggestions as open listing_updates, Upgrades and Prices as
-- admin_next_up() counts them.
create or replace function public.quality_counts()
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with c as (
    select v.business_status
      from public.venues v
     where (v.closed_seen_at is not null and v.closed_dismissed_at is null
            and v.website_retired_at is null
            and v.website_status in ('published_hidden', 'released'))
        or (v.website_retired_at is not null and v.website_retire_done_at is null)
  )
  select jsonb_build_object(
    'closed_temp', (select count(*) from c where business_status = 'CLOSED_TEMPORARILY'),
    'closed_perm', (select count(*) from c where business_status is distinct from 'CLOSED_TEMPORARILY'),
    'no_location', (select count(*) from public.venues v
                     where v.webflow_cms_id is not null
                       and v.website_status in ('released', 'published_hidden')
                       and v.webflow_location_id is null
                       and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
                       and coalesce(v.website_location_override, '') <> 'none'
                       and v.website_location_apply is null
                       and nullif(btrim(coalesce(v.website_new_location, '')), '') is null),
    'not_for_site', (select count(*) from public.venues v
                      where v.status = 'verified' and v.website_status = 'not_on_site'
                        and v.website_dismissed_at is not null),
    'suggestions', (select count(*) from public.listing_updates u where u.status = 'open'),
    'upgrades', (select count(*) from public.page_upgrades u
                  where u.kind <> 'photos' and u.status in ('proposed', 'failed')),
    'prices', (select count(*) from public.product_changes p
                where p.status in ('proposed', 'failed')))
$$;
revoke all on function public.quality_counts() from public, anon, authenticated;

create or replace function public.quality_snapshot()
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  c jsonb := public.quality_counts();
begin
  insert into public.quality_daily (day, closed_temp, closed_perm, no_location,
                                    not_for_site, suggestions, upgrades, prices,
                                    estimated, taken_at)
  values ((now() at time zone 'utc')::date,
          (c ->> 'closed_temp')::int, (c ->> 'closed_perm')::int, (c ->> 'no_location')::int,
          (c ->> 'not_for_site')::int, (c ->> 'suggestions')::int, (c ->> 'upgrades')::int,
          (c ->> 'prices')::int, false, now())
  on conflict (day) do update set
    closed_temp = excluded.closed_temp, closed_perm = excluded.closed_perm,
    no_location = excluded.no_location, not_for_site = excluded.not_for_site,
    suggestions = excluded.suggestions, upgrades = excluded.upgrades,
    prices = excluded.prices, estimated = false, taken_at = excluded.taken_at;
  return c;
end $$;
revoke all on function public.quality_snapshot() from public, anon, authenticated;

-- The past for Closed, from 22 Sep 2026 (the first Google check) to
-- yesterday: a place counts on a day when Google had reported it by
-- then and its page had not yet been retired (or the report set aside).
-- The split into temporary and permanent is as Google reports it today.
insert into public.quality_daily (day, closed_temp, closed_perm, estimated)
select d::date,
       count(v.id) filter (where v.business_status = 'CLOSED_TEMPORARILY'),
       count(v.id) filter (where v.business_status is distinct from 'CLOSED_TEMPORARILY'),
       true
  from generate_series(date '2026-09-22', (now() at time zone 'utc')::date - 1, interval '1 day') d
  left join public.venues v
    on v.closed_seen_at::date <= d::date
   and (v.closed_dismissed_at is null or v.closed_dismissed_at::date > d::date)
   and ((v.website_retired_at is null and v.website_status in ('published_hidden', 'released'))
        or v.website_retired_at::date > d::date)
 group by 1
on conflict (day) do nothing;

select public.quality_snapshot();

-- For the chart: the stored days, then today as it stands this minute.
create or replace function public.admin_quality_history(p_days integer default 90)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  today date := (now() at time zone 'utc')::date;
  c     jsonb;
  days  jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  c := public.quality_counts();
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', q.day, 'closed_temp', q.closed_temp, 'closed_perm', q.closed_perm,
           'no_location', q.no_location, 'estimated', q.estimated) order by q.day), '[]'::jsonb)
    into days
    from public.quality_daily q
   where q.day > today - greatest(coalesce(p_days, 90), 7) and q.day < today;
  days := days || jsonb_build_array(jsonb_build_object(
           'day', today, 'closed_temp', c -> 'closed_temp', 'closed_perm', c -> 'closed_perm',
           'no_location', c -> 'no_location', 'estimated', false));
  return jsonb_build_object(
    'days', days, 'now', c,
    'counted_from', (select min(q.day) from public.quality_daily q where not q.estimated));
end $$;
revoke all on function public.admin_quality_history(integer) from public, anon;
grant execute on function public.admin_quality_history(integer) to authenticated;

-- "11 fewer than a week ago", for the email.
create or replace function public.quality_change_words(p_now integer, p_before integer)
returns text
language sql immutable
as $$
  select case when p_before is null or p_now is null then 'no figure a week ago yet'
              when p_now = p_before then 'the same as a week ago'
              when p_now < p_before then (p_before - p_now) || ' fewer than a week ago'
              else (p_now - p_before) || ' more than a week ago' end
$$;

-- The weekly email. p_dry: build it and hand it back, send nothing.
create or replace function public.quality_weekly_send(
  p_to text default 'jonathan@nomadwise.io', p_dry boolean default false)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  today  date := (now() at time zone 'utc')::date;
  c      jsonb := public.quality_counts();
  wk     public.quality_daily%rowtype;
  d      record;
  n_temp int := (c ->> 'closed_temp')::int;
  n_perm int := (c ->> 'closed_perm')::int;
  n_closed int;
  n_loc  int := (c ->> 'no_location')::int;
  n_sug  int := (c ->> 'suggestions')::int;
  n_upg  int := (c ->> 'upgrades')::int;
  n_pri  int := (c ->> 'prices')::int;
  n_hid  int := (c ->> 'not_for_site')::int;
  total  int;
  mx     int := 0;
  first_day date;
  bars   text := '';
  h1     int;
  h2     int;
  font   text := 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;';
  td     text := 'padding:9px 0;border-top:1px solid #E6E9ED;font-size:15px;line-height:1.4;color:#142032;';
  subj   text;
  lead   text;
  tbl    text;
  html   text;
  txt    text;
  token  text;
  req    bigint;
begin
  n_closed := n_temp + n_perm;
  total := n_closed + n_loc + n_sug + n_upg + n_pri;
  select * into wk from public.quality_daily q where q.day = today - 7;

  -- the last 28 days of Clean-up, today as it stands
  select greatest(coalesce(max(q.closed_temp + q.closed_perm), 0), n_closed),
         coalesce(min(q.day), today)
    into mx, first_day
    from public.quality_daily q where q.day between today - 27 and today - 1;

  for d in
    select q.day, q.closed_temp + q.closed_perm as closed, coalesce(q.no_location, 0) as noloc
      from public.quality_daily q where q.day between today - 27 and today - 1
    union all
    select today, n_closed, n_loc
    order by 1
  loop
    h1 := case when d.closed <= 0 or mx = 0 then 0 else greatest(2, round(120.0 * d.closed / mx)::int) end;
    h2 := 0;  -- Closed only: No Location has no past to draw yet
    bars := bars || '<td valign="bottom" style="vertical-align:bottom;padding:0 1px;">'
         || case when h2 > 0 then '<div style="height:' || h2 || 'px;background:#96A0AC;font-size:0;line-height:0;">&nbsp;</div>' else '' end
         || case when h1 > 0 then '<div style="height:' || h1 || 'px;background:#FF444F;font-size:0;line-height:0;">&nbsp;</div>' else '' end
         || case when h1 + h2 = 0 then '<div style="height:1px;background:#E6E9ED;font-size:0;line-height:0;">&nbsp;</div>' else '' end
         || '</td>';
  end loop;

  subj := 'Quality this week: ' || total || ' waiting';
  lead := case when total = 0 then 'Nothing is waiting in Quality. That is the aim.'
               else 'Everything in Quality that needs a decision from you. The aim is to get this to none.' end;

  tbl := '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 20px;">'
      || '<tr><td style="' || td || '">Closed places to decide on'
      || '<br><span style="font-size:13px;color:#5C6773;">' || n_temp || ' temporarily closed, ' || n_perm || ' permanently. '
      || initcap(left(public.quality_change_words(n_closed, wk.closed_temp + wk.closed_perm), 1))
      || substr(public.quality_change_words(n_closed, wk.closed_temp + wk.closed_perm), 2) || '.</span></td>'
      || '<td align="right" style="' || td || 'font-weight:700;vertical-align:top;">' || n_closed || '</td></tr>'
      || '<tr><td style="' || td || '">Live pages with no Location'
      || '<br><span style="font-size:13px;color:#5C6773;">'
      || initcap(left(public.quality_change_words(n_loc, wk.no_location), 1))
      || substr(public.quality_change_words(n_loc, wk.no_location), 2) || '.</span></td>'
      || '<td align="right" style="' || td || 'font-weight:700;vertical-align:top;">' || n_loc || '</td></tr>'
      || '<tr><td style="' || td || '">Suggestions from visitors</td>'
      || '<td align="right" style="' || td || 'font-weight:700;">' || n_sug || '</td></tr>'
      || '<tr><td style="' || td || '">Text upgrades waiting for your Go</td>'
      || '<td align="right" style="' || td || 'font-weight:700;">' || n_upg || '</td></tr>'
      || '<tr><td style="' || td || '">Price changes waiting for your Go</td>'
      || '<td align="right" style="' || td || 'font-weight:700;">' || n_pri || '</td></tr>'
      || '</table>';

  html := '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      || '<title>Quality this week</title></head>'
      || '<body style="margin:0;padding:0;background:#F7F8F9;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F7F8F9;">'
      || '<tr><td align="center" style="padding:28px 16px;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">'
      || '<tr><td style="padding:0 6px 14px;' || font || '">'
      || '<img src="https://nomadmaps.io/email/nomadwise-logo.png" width="150" height="44" alt="nomadwise.io" style="display:inline-block;border:0;width:150px;height:44px;color:#FF444F;font-size:20px;font-weight:800;">'
      || '</td></tr>'
      || '<tr><td style="background:#ffffff;border:1px solid rgba(20,32,50,0.10);border-radius:8px;padding:30px 30px 26px;' || font || '">'
      || '<p style="margin:0 0 4px;font-size:13px;line-height:1.4;font-weight:700;color:#5C6773;">QUALITY, WEEK TO '
      || upper(to_char(today, 'FMDD Mon YYYY')) || '</p>'
      || '<p style="margin:0 0 8px;font-size:24px;line-height:1.25;font-weight:800;color:#142032;">' || total || ' waiting</p>'
      || '<p style="margin:0 0 22px;font-size:15px;line-height:1.6;color:#3E4C59;">' || lead || '</p>'
      || '<p style="margin:0 0 8px;font-size:13px;line-height:1.4;font-weight:700;color:#142032;">Closed places waiting, day by day</p>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="table-layout:fixed;height:120px;border-bottom:1px solid #C9CED6;">'
      || '<tr style="height:120px;">' || bars || '</tr></table>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:4px 0 6px;"><tr>'
      || '<td style="font-size:12px;color:#5C6773;">' || to_char(first_day, 'FMDD Mon') || '</td>'
      || '<td align="right" style="font-size:12px;color:#5C6773;">' || to_char(today, 'FMDD Mon') || '</td></tr></table>'
      || '<p style="margin:0 0 22px;font-size:12px;line-height:1.6;color:#5C6773;">'
      || 'The tallest bar is ' || mx || '. Days before '
      || coalesce(to_char((select min(q.day) from public.quality_daily q where not q.estimated), 'FMDD Mon'), 'today')
      || ' are worked out from when each closure was reported and each page retired.</p>'
      || tbl
      || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 20px;">'
      || '<tr><td style="background:#FF444F;border-radius:8px;">'
      || '<a href="https://nomadmaps.io/" style="display:inline-block;padding:13px 22px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">Open Nomad Maps</a>'
      || '</td></tr></table>'
      || '<p style="margin:0;font-size:13px;line-height:1.6;color:#5C6773;">Quality is in the menu, then Clean-up. '
      || 'Also kept off the site as not for it: ' || n_hid || '. Nothing to do there.</p>'
      || '</td></tr>'
      || '<tr><td style="padding:16px 6px 0;' || font || 'font-size:12px;line-height:1.6;color:#96A0AC;">'
      || 'Sent every Monday morning to jonathan@nomadwise.io only, from Nomad Maps.'
      || '</td></tr></table></td></tr></table></body></html>';

  txt := 'Quality, week to ' || to_char(today, 'FMDD Mon YYYY') || E'\n\n'
      || total || ' waiting. ' || lead || E'\n\n'
      || 'Closed places to decide on: ' || n_closed || ' (' || n_temp || ' temporarily, ' || n_perm || ' permanently)' || E'\n'
      || 'Live pages with no Location: ' || n_loc || E'\n'
      || 'Suggestions from visitors: ' || n_sug || E'\n'
      || 'Text upgrades waiting for your Go: ' || n_upg || E'\n'
      || 'Price changes waiting for your Go: ' || n_pri || E'\n\n'
      || 'Open Nomad Maps: https://nomadmaps.io/' || E'\n\n'
      || 'Sent every Monday morning to jonathan@nomadwise.io only.';

  if p_dry then
    return jsonb_build_object('sent', false, 'subject', subj, 'html', html, 'text', txt, 'counts', c);
  end if;

  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if coalesce(token, '') = '' then
    raise exception 'No Postmark token in Vault (postmark_server_token).';
  end if;
  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := jsonb_build_object(
      'From', 'Nomad Maps <spaces@nomadwise.io>',
      'To', p_to,
      'Subject', subj,
      'TextBody', txt,
      'HtmlBody', html,
      'MessageStream', 'outbound',
      'Tag', 'quality_weekly'),
    headers := jsonb_build_object(
      'X-Postmark-Server-Token', token,
      'Accept', 'application/json',
      'Content-Type', 'application/json'),
    timeout_milliseconds := 15000)
  into req;
  insert into public.quality_emails (to_email, subject, counts, provider_req)
  values (p_to, subj, c, req::text);
  return jsonb_build_object('sent', true, 'to', p_to, 'subject', subj, 'req', req);
end $$;
revoke all on function public.quality_weekly_send(text, boolean) from public, anon, authenticated;

select cron.unschedule(jobname) from cron.job where jobname in ('quality-snapshot', 'quality-weekly');
select cron.schedule('quality-snapshot', '50 23 * * *', 'select public.quality_snapshot()');
select cron.schedule('quality-weekly', '31 7 * * 1', 'select public.quality_weekly_send()');
