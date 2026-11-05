-- Migration 253: the monthly performance email to owners (step 4).
--
-- Jonathan, 5 Nov 2026: one merged email (A + B + C) sent from Postmark
-- with the shared "nomadwise-layout" layout, as Postmark template
-- "owner-monthly" (source in scripts/postmark/owner-monthly.html and
-- .txt) on its own transactional stream "monthly".
--
-- Rules (Jonathan): only activity worth showing, so a number that is 0
-- is left out, and an owner whose page had nothing at all that month
-- (no Google, no views, no directions, no requests) gets no email that
-- month. A space whose owner joined in the last 10 days of the month
-- gets its first email the month after. "Up X%" only when it went up. Always ends with "Get more from
-- your page" (page_parts, migration 252).
--
-- Who gets it: every claimed space whose page is live, at the owner's
-- email, unless they switched "Monthly performance" off in Settings or
-- with the link in the email (owner_email_prefs, migration 251). One
-- email per space per month (owner_emails kind 'monthly', ref
-- monthly:<space id>:<YYYY-MM>).
--
-- When: owner_monthly_run() every morning 09:23 UTC on the 4th to the
-- 10th. It sends last month's email once Search Console has the whole
-- month (gsc_listing_imports last_day), or on the 8th whatever the
-- Google numbers say. Already-sent spaces are skipped, so the daily
-- runs are safe.

-- What one month looks like for one space: the Postmark template model.
create or replace function public.owner_monthly_model(p_venue uuid, p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v      public.venues%rowtype;
  m      date := date_trunc('month', p_month)::date;
  e      date := (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date;
  pm     date := (date_trunc('month', p_month) - interval '1 month')::date;
  g      int; g_prev int;
  views  int; dirs int; reqs int;
  g_from date;
  up     int;
  tiles  jsonb := '[]'::jsonb;
  bars   jsonb;
  top_   int;
  with_g int;
  parts  jsonb;
  nxt    text;
  steps  jsonb;
  rule   jsonb := public.free_enquiry_rule();
  used   int;
  first_ text;
  city   text;
  page   text;
  n_tiles int;
  acct   text := 'https://nomadmaps.io/owner';
begin
  select * into v from public.venues where id = p_venue;
  if not found then return null; end if;

  select coalesce(sum(impressions), 0) into g from public.page_google_days
   where venue_id = v.id and day between m and e;
  select min(day) into g_from from public.page_google_days;
  if g_from is not null and g_from <= pm then
    select coalesce(sum(impressions), 0) into g_prev from public.page_google_days
     where venue_id = v.id and day >= pm and day < m;
  end if;
  if coalesce(g_prev, 0) > 0 and g > g_prev then
    up := round((g - g_prev) * 100.0 / g_prev);
  end if;

  select coalesce(sum(n) filter (where kind = 'view'), 0),
         coalesce(sum(n) filter (where kind = 'directions'), 0)
    into views, dirs
    from public.page_counts where venue_id = v.id and day between m and e;
  select count(*) into reqs from public.enquiries
   where venue_id = v.id and status <> 'closed'
     and created_at >= m and created_at < e + 1;

  if views > 0 then
    tiles := tiles || jsonb_build_object('value', to_char(views, 'FM999,999,999'),
      'label', case when views = 1 then 'page view' else 'page views' end,
      'label_text', 'Page views');
  end if;
  if dirs > 0 then
    tiles := tiles || jsonb_build_object('value', to_char(dirs, 'FM999,999,999'),
      'label', 'asked for directions', 'label_text', 'Asked for directions');
  end if;
  if reqs > 0 then
    tiles := tiles || jsonb_build_object('value', to_char(reqs, 'FM999,999,999'),
      'label', case when reqs = 1 then 'request sent to you' else 'requests sent to you' end,
      'label_text', 'Requests');
  end if;
  n_tiles := jsonb_array_length(tiles);
  select coalesce(jsonb_agg(t || jsonb_build_object(
           'width', (100 / greatest(n_tiles, 1)) || '%',
           'gap', case when i < n_tiles then '8px' else '0' end) order by i), '[]'::jsonb)
    into tiles
    from jsonb_array_elements(tiles) with ordinality as x(t, i);

  -- six months of Google, shown once three of them have numbers
  select jsonb_agg(jsonb_build_object('mon', mm, 'n', coalesce(s.n, 0)) order by mm)
    into bars
    from generate_series(m - interval '5 months', m, interval '1 month') as mm
    left join lateral (select sum(impressions)::int n from public.page_google_days
                        where venue_id = v.id and day >= mm and day < mm + interval '1 month') s on true;
  select max((b ->> 'n')::int), count(*) filter (where (b ->> 'n')::int > 0)
    into top_, with_g from jsonb_array_elements(bars) b;
  select jsonb_agg(jsonb_build_object(
           'n', to_char((b ->> 'n')::int, 'FM999,999,999'),
           'm', to_char((b ->> 'mon')::timestamp, 'Mon'),
           'h', greatest(round(64.0 * (b ->> 'n')::int / greatest(top_, 1)), case when (b ->> 'n')::int > 0 then 3 else 1 end),
           'color', case when (b ->> 'mon')::date = m then '#FF444F' else '#FFD3D6' end) order by o)
    into bars
    from jsonb_array_elements(bars) with ordinality as x(b, o);

  -- the checklist
  parts := public.page_parts(v.id);
  nxt := parts ->> 'next';
  select jsonb_agg(jsonb_build_object(
           'label', l.label, 'why', l.why,
           'done', (p ->> 'done')::boolean,
           'add_url', acct,
           'add_label', case when p ->> 'key' = 'wifi' then 'Tell us' else 'Add' end,
           'dot', case when (p ->> 'done')::boolean then '&#10003;' else '' end,
           'text_mark', case when (p ->> 'done')::boolean then '[done]' else '[to add]' end,
           'dot_style', case when (p ->> 'done')::boolean
                             then 'background:#1E7A46;color:#FFFFFF;'
                             else 'background:#FFFFFF;border:2px solid #C9CED4;width:16px;height:16px;line-height:16px;' end,
           'label_style', case when (p ->> 'done')::boolean
                               then 'color:#5B636E;' else 'color:#1F2328;font-weight:600;' end,
           'row_border', case when o > 1 then 'border-top:1px solid #ECEDF0;' else '' end) order by o)
    into steps
    from jsonb_array_elements(parts -> 'parts') with ordinality as x(p, o)
    join (values
      ('photos', 'Photos', 'The first thing people look at'),
      ('hours', 'Opening hours', 'So people know when to come'),
      ('description', 'Description', 'What makes your space different'),
      ('prices', 'Prices', 'People can pick one and ask about it'),
      ('wifi', 'Wi-Fi speed', 'The question remote workers ask most')) as l(k, label, why)
      on l.k = p ->> 'key';

  used := public.free_enquiries_used(v.id);
  first_ := nullif(split_part(btrim(coalesce(v.listing_owner_name, '')), ' ', 1), '');
  city := nullif(btrim(coalesce(v.city, '')), '');
  page := 'https://www.nomadwise.io/coworking/' || v.webflow_slug;

  return jsonb_build_object(
    'for_spaces', true,
    'preview', case when g > 0
      then v.name || ' was shown ' || to_char(g, 'FM999,999,999') || ' times in Google search in ' || trim(to_char(m, 'Month')) || '.'
      else 'How ' || v.name || ' did on Nomadwise in ' || trim(to_char(m, 'Month')) || '.' end,
    'subject', case when g > 0
      then v.name || ' in ' || trim(to_char(m, 'Month')) || ': shown ' || to_char(g, 'FM999,999,999') || ' times in Google'
      else 'Your month on Nomadwise: ' || v.name || ', ' || trim(to_char(m, 'Month')) end,
    'first_name', coalesce(first_, 'there'),
    'space', v.name,
    'month_name', trim(to_char(m, 'Month')),
    'month_upper', upper(trim(to_char(m, 'Month'))) || ' ' || to_char(m, 'YYYY'),
    'last_day', extract(day from e)::int,
    'show_google', g > 0,
    'google', to_char(g, 'FM999,999,999'),
    'has_up', up is not null and up >= 1,
    'up_text', 'up ' || coalesce(up, 0) || '% on ' || trim(to_char(pm, 'Month')),
    'google_note', 'People looking for a place to work'
                   || coalesce(' in ' || city, '') || ' saw ' || v.name || ' in their results.',
    'has_tiles', n_tiles > 0,
    'tiles', tiles,
    'show_free', coalesce(v.listing_tier, 'free') <> 'verified'
                 and (rule ->> 'on')::boolean and used > 0,
    'free_used', least(used, (rule ->> 'limit')::int),
    'free_limit', (rule ->> 'limit')::int,
    'premium_url', acct,
    'show_bars', with_g >= 3,
    'bars', bars,
    'parts_done', (parts ->> 'done')::int,
    'parts_total', (parts ->> 'total')::int,
    'parts_pct', greatest(round(100.0 * (parts ->> 'done')::int / greatest((parts ->> 'total')::int, 1)), 1),
    'has_next', nxt is not null,
    'all_done', nxt is null,
    'next_title', case nxt when 'prices' then 'Add your prices'
                           when 'photos' then 'Add photos'
                           when 'description' then 'Write your description'
                           when 'wifi' then 'Tell us your Wi-Fi speed'
                           when 'hours' then 'Add your opening hours' end,
    'next_why', case nxt
      when 'prices' then 'With prices on your page, people pick a day pass, desk or meeting room and send you a request about it in one go. It is the quickest way to turn a page view into a request.'
      when 'photos' then 'Photos are the first thing people look at. Show your desks, the light and the coffee, so people can picture working there.'
      when 'description' then 'Tell people what makes your space different: the feel, who works there and what is close by.'
      when 'wifi' then 'It is the first thing remote workers ask. Send us your speed and we add it to your page.'
      when 'hours' then 'So people know when they can come.' end,
    'next_button', case nxt when 'prices' then 'Add prices'
                            when 'photos' then 'Add photos'
                            when 'description' then 'Write it'
                            when 'wifi' then 'Send your speed'
                            when 'hours' then 'Add hours' end,
    'next_url', acct,
    'steps', coalesce(steps, '[]'::jsonb),
    'account_url', acct,
    'settings_url', acct,
    'page_url', page,
    -- for owner_monthly_send: is there anything worth an email?
    'worth_sending', g > 0 or views > 0 or dirs > 0 or reqs > 0);
end $function$;

revoke all on function public.owner_monthly_model(uuid, date) from public, anon, authenticated;

-- Sends last month's email (or p_month's). p_test_to: send every email
-- to this address instead, marked as a test and not counted as sent.
-- p_venue: only this space. p_dry: build the list, send nothing.
create or replace function public.owner_monthly_send(
  p_month date default null, p_test_to text default null,
  p_venue uuid default null, p_dry boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  mon    date := coalesce(date_trunc('month', p_month)::date,
                          (date_trunc('month', now() at time zone 'utc') - interval '1 month')::date);
  token  text;
  r      record;
  mdl    jsonb;
  v_ref  text;
  dest   text;
  pl     jsonb;
  req    bigint;
  sent   int := 0;
  quiet  int := 0;
  off    int := 0;
  done   int := 0;
  young  int := 0;
  joined timestamptz;
  list   jsonb := '[]'::jsonb;
begin
  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if coalesce(token, '') = '' and not p_dry then
    raise exception 'No Postmark token in Vault (postmark_server_token).';
  end if;

  for r in
    select v.id, v.name, lower(btrim(v.listing_owner_email)) as em
      from public.venues v
     where coalesce(btrim(v.listing_owner_email), '') <> ''
       and coalesce(v.webflow_slug, '') <> ''
       and v.website_status = 'released'
       and (p_venue is null or v.id = p_venue)
     order by v.name
  loop
    v_ref := 'monthly:' || r.id || ':' || to_char(mon, 'YYYY-MM');
    if p_test_to is null then
      if not public.owner_wants_email(r.em, 'monthly') then
        off := off + 1; continue;
      end if;
      if exists (select 1 from public.owner_emails o
                  where o.ref = v_ref and o.kind = 'monthly' and o.status = 'sent') then
        done := done + 1; continue;
      end if;
    end if;
    -- New to Nomadwise in the last 10 days of the month (or after it):
    -- no email yet, their first one comes the month after (Jonathan,
    -- 5 Nov: a few days of numbers would be pointless).
    select max(c.approved_at) into joined
      from public.listing_claims c
     where c.venue_id = r.id and lower(btrim(c.owner_email)) = r.em
       and c.approved_at is not null;
    if p_test_to is null and joined is not null
       and (joined at time zone 'utc')::date > (mon + interval '1 month' - interval '11 days')::date then
      young := young + 1; continue;
    end if;
    mdl := public.owner_monthly_model(r.id, mon);
    if not coalesce((mdl ->> 'worth_sending')::boolean, false) then
      quiet := quiet + 1; continue;
    end if;
    dest := coalesce(lower(btrim(p_test_to)), r.em);
    mdl := mdl || jsonb_build_object('stop_url',
      'https://nomadmaps.io/stop/?t=' || public.owner_email_token(r.em));
    list := list || jsonb_build_object('space', r.name, 'to', dest, 'subject', mdl ->> 'subject');
    if p_dry then continue; end if;

    pl := jsonb_build_object(
      'From', 'Nomadwise Spaces <spaces@nomadwise.io>',
      'To', dest,
      'ReplyTo', 'spaces@nomadwise.io',
      'TemplateAlias', 'owner-monthly',
      'TemplateModel', mdl,
      'MessageStream', 'monthly',
      'Tag', 'monthly');
    select net.http_post(
      url := 'https://api.postmarkapp.com/email/withTemplate',
      body := pl,
      headers := jsonb_build_object(
        'X-Postmark-Server-Token', token,
        'Accept', 'application/json',
        'Content-Type', 'application/json'),
      timeout_milliseconds := 15000)
    into req;
    -- payload left out on purpose: owner_emails_retry re-posts payloads
    -- to /email, which does not take templates.
    insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, cta_url, venue_id, attempts, last_try_at)
    values (case when p_test_to is null then 'monthly' else 'monthly_test' end,
            dest, mdl ->> 'subject', v_ref, 'sent', req::text,
            'Monthly performance, ' || to_char(mon, 'FMMonth YYYY'),
            'https://nomadmaps.io/owner', r.id, 1, now());
    sent := sent + 1;
  end loop;

  return jsonb_build_object('month', to_char(mon, 'YYYY-MM'), 'sent', sent,
    'nothing_to_show', quiet, 'switched_off', off, 'already_sent', done,
    'too_new', young,
    'emails', list, 'dry', p_dry);
end $function$;

revoke all on function public.owner_monthly_send(date, text, uuid, boolean) from public, anon, authenticated;

-- Every morning from the 4th to the 10th: send last month's emails once
-- Google has the whole month, or on the 8th regardless.
create or replace function public.owner_monthly_run()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  today date := (now() at time zone 'utc')::date;
  last_m date := (date_trunc('month', today) - interval '1 day')::date;
  g_to  date;
begin
  if extract(day from today) not between 4 and 10 then
    return jsonb_build_object('skipped', 'not the 4th to the 10th');
  end if;
  select max(day) into g_to from public.page_google_days;
  if coalesce(g_to, '1900-01-01') < last_m and extract(day from today) < 8 then
    return jsonb_build_object('waiting', 'Google numbers only up to ' || coalesce(g_to::text, 'none'));
  end if;
  return public.owner_monthly_send(null, null, null, false);
end $function$;

revoke all on function public.owner_monthly_run() from public, anon, authenticated;

do $cron$
begin
  if exists (select 1 from cron.job where jobname = 'owner-monthly') then
    perform cron.unschedule('owner-monthly');
  end if;
  perform cron.schedule('owner-monthly', '23 9 4-10 * *', 'select public.owner_monthly_run()');
end
$cron$;
