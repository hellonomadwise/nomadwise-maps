-- ============================================================
-- Migration 269: the Emails view of the Owner flow.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: "an overview of what emails were sent out ...
-- along the lines where we have the owner flow ... how many were sent,
-- split between cafes and coworking spaces, who opened them ... how many
-- actually used them ... did the tip ... and ultimately becoming
-- premium". Built for every owner email, the monthly one first.
--
--   owner_emails.message_id  Postmark's id for each email we send, so
--                            its opens and clicks match it exactly.
--                            Taken from the send's reply, or (for older
--                            emails, Postmark keeps 45 days) found in
--                            Postmark's list of sent messages.
--   owner_emails.meta        what the email suggested (the monthly
--                            email's tip), to check later if it was done.
--   email_events             opens, clicks and bounces, read from
--                            Postmark every hour.
--   admin_email_flow(from)   everything the Emails view shows.
--
-- Clicks from inbox security scanners are left out: they "click" every
-- link in an email within a few seconds of it arriving (seen on the
-- first monthly send). A click counts only when no other link in the
-- same email was clicked within 5 seconds of it.
-- Team and test addresses are left out, as in the Owner flow.
-- ============================================================

alter table public.owner_emails
  add column if not exists message_id text,
  add column if not exists meta jsonb;
create index if not exists owner_emails_message_id on public.owner_emails (message_id);

create table if not exists public.email_events (
  id          bigserial primary key,
  kind        text not null check (kind in ('open', 'click', 'bounce')),
  message_id  text not null,
  recipient   text,
  tag         text,
  stream      text,
  link        text not null default '',
  platform    text,
  client      text,
  user_agent  text,
  at          timestamptz not null,
  unique (kind, message_id, at, link)
);
create index if not exists email_events_message on public.email_events (message_id);
alter table public.email_events enable row level security;
revoke all on public.email_events from public, anon, authenticated;

-- A GET to Postmark's API, answered there and then.
create or replace function public.pm_get(p_path text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  select * into r from extensions.http(('GET', 'https://api.postmarkapp.com/' || p_path,
    array[extensions.http_header('X-Postmark-Server-Token', public.pm_token()),
          extensions.http_header('Accept', 'application/json')], null, null)::extensions.http_request);
  if r.status <> 200 then raise exception 'Postmark % on %: %', r.status, p_path, left(coalesce(r.content, ''), 200); end if;
  return r.content::jsonb;
end $$;
revoke all on function public.pm_get(text) from public, anon, authenticated;

-- The id from each send's reply (pg_net keeps replies for a few hours).
create or replace function public.email_ids_capture() returns int
language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  update public.owner_emails o set message_id = r.content::jsonb ->> 'MessageID'
    from net._http_response r
   where o.message_id is null and o.provider_req ~ '^\d+$' and r.id = o.provider_req::bigint
     and r.status_code = 200 and r.content ~ '^\s*\{' and (r.content::jsonb ->> 'MessageID') is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.email_ids_capture() from public, anon, authenticated;

-- Older emails: find them in Postmark's list of sent messages (same
-- address, same subject, sent within 15 minutes of our record).
create or replace function public.email_ids_backfill(p_days int default 3) returns int
language plpgsql security definer set search_path to 'public' as $$
declare
  s    text;
  off  int;
  j    jsonb;
  n    int := 0;
  frm  text := to_char((now() - make_interval(days => least(greatest(p_days, 1), 45))) at time zone 'utc', 'YYYY-MM-DD');
begin
  create temp table if not exists _pm_sent (id text, rcpt text, subject text, at timestamptz) on commit drop;
  delete from _pm_sent;
  foreach s in array array['outbound', 'lifecycle', 'enquiries', 'monthly'] loop
    off := 0;
    loop
      j := public.pm_get('messages/outbound?count=500&offset=' || off || '&messagestream=' || s || '&fromdate=' || frm);
      insert into _pm_sent
      select m ->> 'MessageID', lower(rc), m ->> 'Subject', (m ->> 'ReceivedAt')::timestamptz
        from jsonb_array_elements(coalesce(j -> 'Messages', '[]')) m,
             jsonb_array_elements_text(coalesce(m -> 'Recipients', '[]')) rc;
      exit when jsonb_array_length(coalesce(j -> 'Messages', '[]')) < 500 or off >= 9000;
      off := off + 500;
    end loop;
  end loop;
  with pick as (
    select distinct on (o.id) o.id, p.id as mid
      from public.owner_emails o
      join _pm_sent p on p.rcpt = lower(o.to_email)
                     and abs(extract(epoch from (p.at - o.created_at))) < 900
                     and (p.subject = o.subject or p.subject like '%' || o.subject)
     where o.message_id is null
       and not exists (select 1 from public.owner_emails x where x.message_id = p.id)
     order by o.id, abs(extract(epoch from (p.at - o.created_at)))
  )
  update public.owner_emails o set message_id = pick.mid from pick where o.id = pick.id;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.email_ids_backfill(int) from public, anon, authenticated;

-- Opens, clicks and bounces from Postmark, newest first, until we reach
-- what we already have (two days of overlap; duplicates are skipped).
create or replace function public.email_events_sync() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  k     text;
  off   int;
  j     jsonb;
  arr   jsonb;
  since timestamptz;
  oldest timestamptz;
  n     int;
  tot   jsonb := '{}'::jsonb;
begin
  foreach k in array array['open', 'click', 'bounce'] loop
    select coalesce(max(at), 'epoch'::timestamptz) - interval '2 days' into since from public.email_events where kind = k;
    off := 0; n := 0;
    loop
      j := public.pm_get(case k when 'open' then 'messages/outbound/opens'
                                when 'click' then 'messages/outbound/clicks'
                                else 'bounces' end || '?count=500&offset=' || off);
      arr := coalesce(j -> case k when 'open' then 'Opens' when 'click' then 'Clicks' else 'Bounces' end, '[]');
      insert into public.email_events (kind, message_id, recipient, tag, stream, link, platform, client, user_agent, at)
      select k, e ->> 'MessageID', lower(coalesce(e ->> 'Recipient', e ->> 'Email')), e ->> 'Tag', e ->> 'MessageStream',
             coalesce(case k when 'click' then e ->> 'OriginalLink' when 'bounce' then e ->> 'Type' end, ''),
             e ->> 'Platform', e #>> '{Client,Name}', left(e ->> 'UserAgent', 300),
             coalesce(e ->> 'ReceivedAt', e ->> 'BouncedAt')::timestamptz
        from jsonb_array_elements(arr) e
       where e ->> 'MessageID' is not null
      on conflict do nothing;
      n := n + jsonb_array_length(arr);
      select min(coalesce(e ->> 'ReceivedAt', e ->> 'BouncedAt')::timestamptz) into oldest from jsonb_array_elements(arr) e;
      exit when jsonb_array_length(arr) < 500 or oldest < since or off >= 9000;
      off := off + 500;
    end loop;
    tot := tot || jsonb_build_object(k, n);
  end loop;
  return tot;
end $$;
revoke all on function public.email_events_sync() from public, anon, authenticated;

create or replace function public.email_tracking_run() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a int; b int := 0; c jsonb;
begin
  a := public.email_ids_capture();
  -- Postmark keeps 45 days; a few calls, so look back the whole way
  begin b := public.email_ids_backfill(45);
  exception when others then b := -1; end;
  c := public.email_events_sync();
  return jsonb_build_object('ids_from_replies', a, 'ids_from_postmark', b, 'events_read', c);
end $$;
revoke all on function public.email_tracking_run() from public, anon, authenticated;

select cron.unschedule('email-tracking')
 where exists (select 1 from cron.job where jobname = 'email-tracking');
select cron.schedule('email-tracking', '17 * * * *', 'select public.email_tracking_run()');

-- ---------- the monthly email: tip and account links told apart ----------
-- Both buttons went to nomadmaps.io/owner, so a click on the tip could
-- not be told from a click on "Open your Owner account". Each now says
-- where it came from, and the send keeps which tip it suggested.
select public.pm_patch_fn('public.owner_monthly_send(date,text,uuid,boolean)',
$a$    list := list || jsonb_build_object('space', r.name, 'to', dest, 'subject', mdl ->> 'subject');$a$,
$a$    mdl := mdl || jsonb_build_object(
      'next_url', coalesce(mdl ->> 'next_url', '') || case when coalesce(mdl ->> 'next_url', '') like '%?%' then '&' else '?' end || 'from=monthly-tip',
      'account_url', coalesce(mdl ->> 'account_url', '') || case when coalesce(mdl ->> 'account_url', '') like '%?%' then '&' else '?' end || 'from=monthly');
    list := list || jsonb_build_object('space', r.name, 'to', dest, 'subject', mdl ->> 'subject');$a$,
$m$'from=monthly-tip'$m$);

select public.pm_patch_fn('public.owner_monthly_send(date,text,uuid,boolean)',
$a$    insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, cta_url, venue_id, attempts, last_try_at)$a$,
$a$    insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, cta_url, venue_id, attempts, last_try_at, meta)$a$,
$m$last_try_at, meta)$m$);

select public.pm_patch_fn('public.owner_monthly_send(date,text,uuid,boolean)',
$a$            'https://nomadmaps.io/owner', r.id, 1, now());$a$,
$a$            'https://nomadmaps.io/owner', r.id, 1, now(),
            jsonb_build_object('tip', mdl ->> 'next_title', 'tip_key', (public.page_parts(r.id)) ->> 'next',
                               'parts_done', (public.page_parts(r.id)) ->> 'done'));$a$,
$m$'tip_key'$m$);

-- The first send (6 Nov): its tip, from the page as it is (nothing has
-- been completed since it went).
update public.owner_emails o
   set meta = jsonb_build_object('tip_key', (public.page_parts(o.venue_id)) ->> 'next',
                                 'parts_done', (public.page_parts(o.venue_id)) ->> 'done')
 where o.kind = 'monthly' and o.meta is null and o.venue_id is not null;

-- ---------- what the Emails view shows ----------
create or replace function public.admin_email_flow(p_from date default null) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  res jsonb;
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;

  with grp(kind, g, label, ord) as (values
      ('finish_claim', 'finish_claim', 'Finish your claim', 1),
      ('claim_received', 'claim_received', 'Claim received', 2),
      ('payment_received', 'claim_received', 'Claim received', 2),
      ('approved_free', 'approved', 'Claim approved', 3),
      ('approved_verified', 'approved', 'Claim approved', 3),
      ('approved_premium', 'approved', 'Claim approved', 3),
      ('rejected', 'rejected', 'Claim not approved', 4),
      ('signin_reminder_1', 'signin_1', 'Sign-in reminder 1', 5),
      ('signin_reminder_2', 'signin_2', 'Sign-in reminder 2', 6),
      ('page_live', 'page_live', 'Your page is live', 7),
      ('changes_live', 'changes_live', 'Your changes are live', 8),
      ('changes_back', 'changes_back', 'Changes sent back', 9),
      ('chat', 'chat', 'Chat message from us', 10),
      ('monthly', 'monthly', 'Monthly performance', 11),
      ('plan_ended', 'plan_ended', 'Premium ended', 12)
  ), clicks as (
    select c.*,
      not exists (select 1 from public.email_events c2
                   where c2.kind = 'click' and c2.message_id = c.message_id and c2.link <> c.link
                     and abs(extract(epoch from (c2.at - c.at))) <= 5) as human
      from public.email_events c where c.kind = 'click'
  ), s as (
    select o.id, o.kind, grp.g, grp.label, grp.ord, lower(o.to_email) as em, o.created_at as sent_at,
           o.subject, o.meta, o.message_id,
           coalesce(o.venue_id, (select lc.venue_id from public.listing_claims lc
                                  where lower(lc.owner_email) = lower(o.to_email) and lc.venue_id is not null
                                  order by lc.created_at desc limit 1)) as venue_id
      from public.owner_emails o
      join grp on grp.kind = o.kind
     where o.status = 'sent'
       and (p_from is null or o.created_at >= p_from)
       and lower(o.to_email) not in (select email from public.owner_flow_team_emails)
       and lower(o.to_email) not like '%nomadwise%'
  ), r as (
    select s.*,
      v.name as space, case when coalesce(v.type, '') = 'cafe' then 'cafe' else 'cowork' end as vtype,
      (select min(e.at) from public.email_events e where e.message_id = s.message_id and e.kind = 'bounce') as bounced_at,
      least((select min(e.at) from public.email_events e where e.message_id = s.message_id and e.kind = 'open'),
            (select min(c.at) from clicks c where c.message_id = s.message_id and c.human)) as opened_at,
      (select min(c.at) from clicks c where c.message_id = s.message_id and c.human
          and c.link not like '%/stop/%' and c.link not like '%unsubscribe%') as clicked_at,
      (select coalesce(jsonb_agg(distinct case
                 when c.link like '%from=monthly-tip%' then 'tip'
                 when c.link like '%/stop/%' then 'stop'
                 when c.link like '%nomadmaps.io/owner%' then 'owner account'
                 when c.link like '%nomadwise.io/coworking/%' then 'their page'
                 when c.link like '%nomadwise.io%' then 'nomadwise.io'
                 else 'other' end), '[]'::jsonb)
         from clicks c where c.message_id = s.message_id and c.human) as links,
      (select min(greatest(ov.first_at, s.sent_at)) from public.owner_visits ov
        where lower(ov.owner_email) = s.em and ov.last_at >= s.sent_at
          and ov.first_at <= s.sent_at + interval '7 days') as signed_in_at,
      (select min(od.submitted_at) from public.owner_drafts od
        where lower(od.owner_email) = s.em and od.submitted_at >= s.sent_at
          and od.submitted_at <= s.sent_at + interval '14 days') as acted_at,
      case when s.meta ? 'tip_key' and s.venue_id is not null then
        coalesce((select (p ->> 'done')::boolean
                    from jsonb_array_elements((public.page_parts(s.venue_id)) -> 'parts') p
                   where p ->> 'key' = s.meta ->> 'tip_key'), false)
      end as tip_done,
      (select ss.first_paid from public.stripe_subscriptions ss
        where ss.subscription_id = v.stripe_subscription_id
          and ss.first_paid >= s.sent_at::date and ss.first_paid <= (s.sent_at + interval '60 days')::date) as premium_on,
      s.message_id is not null as tracked
      from s left join public.venues v on v.id = s.venue_id
  ), per as (
    select g, label, ord,
      count(*) as sent,
      count(*) filter (where vtype = 'cafe') as cafe,
      count(*) filter (where vtype = 'cowork') as cowork,
      count(*) filter (where tracked) as tracked,
      count(*) filter (where bounced_at is not null) as bounced,
      count(*) filter (where opened_at is not null) as opened,
      count(*) filter (where clicked_at is not null) as clicked,
      count(*) filter (where links ? 'tip') as tip_clicked,
      count(*) filter (where signed_in_at is not null) as signed_in,
      count(*) filter (where acted_at is not null) as acted,
      count(*) filter (where tip_done) as tip_done,
      count(*) filter (where tip_done is not null) as tip_suggested,
      count(*) filter (where premium_on is not null) as premium,
      max(sent_at) as last_sent,
      jsonb_agg(jsonb_build_object(
        'email', em, 'space', space, 'type', vtype, 'sent_at', sent_at, 'subject', subject,
        'tracked', tracked, 'bounced_at', bounced_at, 'opened_at', opened_at, 'clicked_at', clicked_at,
        'links', links, 'signed_in_at', signed_in_at, 'acted_at', acted_at,
        'tip', meta ->> 'tip', 'tip_key', meta ->> 'tip_key', 'tip_done', tip_done, 'premium_on', premium_on
      ) order by sent_at desc) as people
      from r group by g, label, ord
  )
  select jsonb_build_object(
      'emails', coalesce(jsonb_agg(to_jsonb(per) order by per.ord), '[]'::jsonb),
      'from', p_from,
      'tracking_since', (select min(at) from public.email_events),
      'last_read', (select max(end_time) from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                     where j.jobname = 'email-tracking' and d.status = 'succeeded'),
      'as_of', now())
    into res
    from per;
  return res;
end $$;
revoke all on function public.admin_email_flow(date) from public, anon;
grant execute on function public.admin_email_flow(date) to authenticated;
