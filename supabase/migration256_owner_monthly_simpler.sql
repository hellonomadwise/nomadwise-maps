-- Migration 256: the simpler monthly email (Jonathan, 5 Nov 2026: "I
-- think we need to simplify it"). After two rounds of options he chose
-- the first mock-up's Email B ("along this maybe"): "OCTOBER 2026 ·
-- <SPACE>", "Your page was busier this month" (or "Here is how your page
-- did in <month>"), the numbers above 0 two by two, big number first,
-- then a small icon, what it is and a grey note (Jonathan picked this
-- "four big numbers" layout; Google from 20, "Up from N in <month>"), the
-- six-month Google bars once three months have numbers and this month
-- went up (no falling charts), a grey "One
-- thing to try in <next month>" tip, Open your Owner account, sign-off.
-- Icons are PNGs at nomadmaps.io/email/icons/ (email programs do not
-- show SVG). Model fields: eyebrow, headline, grid_html, rows (for the
-- plain-text version), chart.
-- Model changes: "up" only when last month had 20 or more, and "more
-- than double <month>" from 100% (the first test said "up 1717%");
-- up_html, google_text and tip_month for Postmark's template language
-- (inside a block only {{../name}} works and blocks cannot nest);
-- shorter tip texts.

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
  g_min  constant int := 20;  -- Jonathan, 5 Nov: no Google number below 20
  stats  jsonb := '[]'::jsonb;
  n_st   int;
  grid   text;
  t_     jsonb;
  ri     int;
  nr     int;
  st     text;
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
  if coalesce(g_prev, 0) >= g_min and g > g_prev then
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

  -- The rows (Email B, Jonathan 5 Nov: "along this"): an icon, what it
  -- is, a short note and the number; Google first (from 20), then page
  -- views, directions and requests above 0.
  if g >= g_min then
    stats := stats || jsonb_build_object('icon', 'google', 'label', 'Shown in Google',
      'note', case when up >= 1
                   then 'Up from ' || to_char(g_prev, 'FM999,999,999') || ' in ' || trim(to_char(pm, 'Month'))
                   else 'Times your page was in Google results' end,
      'value', to_char(g, 'FM999,999,999'));
  end if;
  if views > 0 then
    stats := stats || jsonb_build_object('icon', 'views', 'label', 'Page views',
      'note', 'People who opened your page', 'value', to_char(views, 'FM999,999,999'));
  end if;
  if dirs > 0 then
    stats := stats || jsonb_build_object('icon', 'directions', 'label', 'Directions',
      'note', 'Tapped Directions on your page', 'value', to_char(dirs, 'FM999,999,999'));
  end if;
  if reqs > 0 then
    stats := stats || jsonb_build_object('icon', 'requests', 'label', 'Requests',
      'note', case when coalesce(v.listing_tier, 'free') <> 'verified' and (rule ->> 'on')::boolean
                        and public.free_enquiries_used(v.id) >= (rule ->> 'limit')::int
                   then (rule ->> 'limit') || ' of ' || (rule ->> 'limit') || ' free used'
                   else 'Sent to you by email' end,
      'value', to_char(reqs, 'FM999,999,999'));
  end if;
  n_st := jsonb_array_length(stats);
  -- Jonathan, 5 Nov: "go for 2": four big numbers, two by two, the
  -- number first, then a small icon with what it is and a grey note;
  -- thin lines between them instead of boxes. Built here as HTML,
  -- because Postmark's template language cannot nest blocks.
  nr := (n_st + 1) / 2;
  grid := '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 24px;">';
  for i in 1 .. n_st loop
    t_ := stats -> (i - 1);
    ri := (i + 1) / 2;
    st := case when i % 2 = 1 then 'padding:0 16px 0 0;' else 'padding:0 0 0 16px;border-left:1px solid #ECEDF0;' end;
    if ri > 1 then st := st || 'padding-top:20px;'; end if;
    if ri < nr then st := st || 'padding-bottom:20px;border-bottom:1px solid #ECEDF0;'; end if;
    if i % 2 = 1 then grid := grid || '<tr>'; end if;
    grid := grid || '<td width="50%" valign="top" style="' || st || '">'
      || '<div style="font-size:40px;font-weight:800;line-height:1;letter-spacing:-1px;color:#1F2328;">' || (t_ ->> 'value') || '</div>'
      || '<div style="margin-top:8px;"><img src="https://nomadmaps.io/email/icons/' || (t_ ->> 'icon') || '.png" width="20" height="20" alt="" style="vertical-align:-5px;margin-right:6px;border:0;">'
      || '<span style="font-size:14.5px;font-weight:600;color:#1F2328;">' || (t_ ->> 'label') || '</span></div>'
      || '<div style="margin-top:3px;font-size:12.5px;line-height:1.4;color:#5B636E;">' || (t_ ->> 'note') || '</div></td>';
    if i % 2 = 0 then grid := grid || '</tr>';
    elsif i = n_st then grid := grid || '<td width="50%"></td></tr>'; end if;
  end loop;
  grid := grid || '</table>';
  if n_st = 0 then grid := ''; end if;

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
           'color', case when (b ->> 'mon')::date = m then '#E2555B' else '#F2D3D5' end) order by o)
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
    'preview', case when g >= g_min
      then v.name || ' was shown ' || to_char(g, 'FM999,999,999') || ' times in Google search in ' || trim(to_char(m, 'Month')) || '.'
      else 'How ' || v.name || ' did on Nomadwise in ' || trim(to_char(m, 'Month')) || '.' end,
    'subject', case when g >= g_min
      then v.name || ' in ' || trim(to_char(m, 'Month')) || ': shown ' || to_char(g, 'FM999,999,999') || ' times in Google'
      else 'Your month on Nomadwise: ' || v.name || ', ' || trim(to_char(m, 'Month')) end,
    'first_name', coalesce(first_, 'there'),
    'space', v.name,
    'month_name', trim(to_char(m, 'Month')),
    'month_upper', upper(trim(to_char(m, 'Month'))) || ' ' || to_char(m, 'YYYY'),
    'last_day', extract(day from e)::int,
    'show_google', g >= g_min,
    'google', to_char(g, 'FM999,999,999'),
    'has_up', up is not null and up >= 1,
    'up_text', case when up >= 100
                    then 'more than double ' || trim(to_char(pm, 'Month'))
                    else 'up ' || coalesce(up, 0) || '% on ' || trim(to_char(pm, 'Month')) end,
    'up_html', case when up >= 1 then
      '<div style="margin-top:6px;"><span style="display:inline-block;padding:5px 10px;border-radius:8px;background:#FFFFFF;font-size:13px;font-weight:700;color:#1E7A46;">&#8593; '
      || case when up >= 100 then 'more than double ' || trim(to_char(pm, 'Month'))
              else 'up ' || up || '% on ' || trim(to_char(pm, 'Month')) end
      || '</span></div>' else '' end,
    'google_text', 'Shown in Google search: ' || to_char(g, 'FM999,999,999')
      || case when up >= 1 then ' (' || case when up >= 100 then 'more than double ' || trim(to_char(pm, 'Month'))
              else 'up ' || up || '% on ' || trim(to_char(pm, 'Month')) end || ')' else '' end,
    'tip_month', trim(to_char(m + interval '1 month', 'Month')),
    'tip_month_upper', upper(trim(to_char(m + interval '1 month', 'Month'))),
    'rows', stats,
    'grid_html', grid,
    'eyebrow', upper(trim(to_char(m, 'Month'))) || ' ' || to_char(m, 'YYYY') || ' · ' || upper(v.name),
    'headline', case when up >= 1 then 'Your page was busier this month'
                     else 'Here is how your page did in ' || trim(to_char(m, 'Month')) end,
    -- the bars only when this month went up: no falling charts
    'chart', case when g >= g_min and with_g >= 3 and coalesce(up, 0) >= 1
                  then bars else '[]'::jsonb end,
    'google_note', 'People looking for a place to work'
                   || coalesce(' in ' || city, '') || ' saw ' || v.name || ' in their results.',
    'has_tiles', n_tiles > 0,
    'tiles', tiles,
    'show_free', coalesce(v.listing_tier, 'free') <> 'verified'
                 and (rule ->> 'on')::boolean and used > 0,
    'free_used', least(used, (rule ->> 'limit')::int),
    'free_limit', (rule ->> 'limit')::int,
    'premium_url', acct,
    'show_bars', g >= g_min and with_g >= 3 and coalesce(up, 0) >= 1,
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
      when 'prices' then 'People can then pick a day pass or desk and send you a request in one go.'
      when 'photos' then 'Photos are the first thing people look at on your page.'
      when 'description' then 'Tell people what makes your space different.'
      when 'wifi' then 'It is the first thing remote workers ask.'
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
    'worth_sending', g >= g_min or views > 0 or dirs > 0 or reqs > 0);
end $function$;

revoke all on function public.owner_monthly_model(uuid, date) from public, anon, authenticated;
