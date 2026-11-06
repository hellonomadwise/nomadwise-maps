-- ============================================================
-- Migration 275: owner tips, short emails set off by what each owner
-- has or has not done. OFF until Jonathan approves the test emails.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: owner emails should be transactional, specific
-- to each owner, "in a way of creating stickiness", and tracked in the
-- Emails view so we can see what leads to Premium. Not a Kit newsletter.
--
-- The four emails (Postmark templates, stream "lifecycle"):
--   tip-next           3 to 21 days after their changes (or page) went
--                      live, page not complete: the one thing missing,
--                      once per missing thing.
--   tip-complete       the day the page becomes complete (photos,
--                      opening hours, description, prices, Wi-Fi: the
--                      "Get more from your page" checklist), once.
--   tip-quiet          30 days or more without signing in or sending an
--                      edit, and their page had something since: their
--                      own numbers. At most once every 30 days.
--   tip-first-request  1 to 7 days after the first request ever sent
--                      to them, once.
-- Rules: one tip a week at most per owner; none from the 1st to the
-- 10th of the month (the monthly email's week) or within 5 days after
-- a monthly email; only owners whose page is live; never our own
-- addresses; never anyone who switched "Tips for your page" off (in
-- Settings, or with the link in the email). If two are due, the first
-- request comes first, then complete, then next, then quiet.
--
-- Switch: sync_settings 'owner_tips' {"on": false} here. To switch on
-- (Claude does this once Jonathan has said ok to the test emails):
--   update public.email_templates set live = true where alias like 'tip-%';
--   update public.sync_settings set value = '{"on": true}' where key = 'owner_tips';
-- ============================================================

-- ---------- the switch for owners ----------
alter table public.owner_email_prefs add column if not exists tips boolean not null default true;

create or replace function public.owner_wants_email(p_email text, p_key text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select case p_key when 'monthly' then p.monthly
                       when 'chat_replies' then p.chat_replies
                       when 'tips' then p.tips end
       from public.owner_email_prefs p
      where p.email = lower(btrim(coalesce(p_email, '')))),
    true);
$$;

create or replace function public.owner_email_prefs_get()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  em text := public.owner_email();
  p  public.owner_email_prefs%rowtype;
begin
  if em is null then
    raise exception 'Please sign in again.';
  end if;
  select * into p from public.owner_email_prefs where email = em;
  return jsonb_build_object(
    'monthly', coalesce(p.monthly, true),
    'chat_replies', coalesce(p.chat_replies, true),
    'tips', coalesce(p.tips, true));
end $function$;

create or replace function public.owner_email_prefs_set(p_key text, p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  em text := public.owner_email();
begin
  if em is null then
    raise exception 'Please sign in again.';
  end if;
  if p_key not in ('monthly', 'chat_replies', 'tips') or p_on is null then
    raise exception 'Unknown setting.';
  end if;
  insert into public.owner_email_prefs (email) values (em)
  on conflict (email) do nothing;
  update public.owner_email_prefs
     set monthly = case when p_key = 'monthly' then p_on else monthly end,
         chat_replies = case when p_key = 'chat_replies' then p_on else chat_replies end,
         tips = case when p_key = 'tips' then p_on else tips end,
         updated_at = now()
   where email = em;
  return public.owner_email_prefs_get();
end $function$;

create or replace function public.owner_email_pref_off(p_token text, p_key text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  em text;
begin
  if p_key not in ('monthly', 'chat_replies', 'tips') then
    return jsonb_build_object('ok', false);
  end if;
  update public.owner_email_prefs
     set monthly = case when p_key = 'monthly' then false else monthly end,
         chat_replies = case when p_key = 'chat_replies' then false else chat_replies end,
         tips = case when p_key = 'tips' then false else tips end,
         updated_at = now()
   where token = btrim(coalesce(p_token, ''))
  returning email into em;
  return jsonb_build_object('ok', em is not null);
end $function$;

-- ---------- what each page looked like last time we checked ----------
-- So "page complete" goes only to a page that becomes complete from
-- now on, not to every page that already was.
create table if not exists public.owner_page_state (
  venue_id     uuid primary key references public.venues(id) on delete cascade,
  done         int not null,
  total        int not null,
  complete_at  timestamptz,
  checked_at   timestamptz not null default now()
);
alter table public.owner_page_state enable row level security;
revoke all on public.owner_page_state from public, anon, authenticated;

insert into public.sync_settings (key, value)
values ('owner_tips', '{"on": false}'::jsonb)
on conflict (key) do nothing;

-- ---------- the four templates (not live until approved) ----------
do $tpl$
declare
  p    text := '<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">';
  btn  text := '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 26px;"><tr><td style="background:#FF444F;border-radius:8px;"><a href="%s" style="display:inline-block;padding:13px 22px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">%s</a></td></tr></table>';
  sig  text := '<p style="margin:8px 0 10px;font-size:16px;line-height:1.6;color:#142032;">Kind regards,</p><p style="margin:0;font-size:16px;line-height:1.4;font-weight:700;color:#142032;">Jonathan Heavens</p><p style="margin:2px 0 0;font-size:14px;line-height:1.5;color:#5C6773;">Co-founder, <a href="https://www.nomadwise.io" style="color:#FF444F;font-weight:700;text-decoration:none;">nomadwise.io</a></p>';
  foot text := E'\n<p style="margin:24px 0 0;font-size:12.5px;line-height:1.5;color:#96A0AC;">You get a tip like this now and then because you manage {{space_name}} on Nomadwise. <a href="{{stop_url}}" style="color:#6B7480;text-decoration:underline;">Stop these tips</a></p>\n';
  sigt text := E'Kind regards,\nJonathan Heavens\nCo-founder, Nomadwise';
  foott text := E'\n\nYou get a tip like this now and then because you manage {{space_name}} on Nomadwise. Stop these tips: {{stop_url}}';
begin
  insert into public.email_templates (alias, name, stream, for_spaces, subject, html_body, text_body, sort, live, test_model)
  values
  ('tip-next', 'Owner tip: the next thing to add', 'lifecycle', true,
   'One thing to add to {{space_name}}',
   p || 'Hi {{first_name}},</p>' || E'\n'
   || p || 'Thanks for your changes to {{space_name}}. They are live on your page now.</p>' || E'\n'
   || p || 'Your page has {{parts_done}} of the {{parts_total}} things people look for before they visit. The one still missing is {{next_label}}.</p>' || E'\n'
   || p || '{{next_why}}</p>' || E'\n'
   || format(btn, '{{owner_url}}', '{{next_button}}') || E'\n' || sig || foot,
   'Hi {{first_name}},' || E'\n\n'
   || 'Thanks for your changes to {{space_name}}. They are live on your page now.' || E'\n\n'
   || 'Your page has {{parts_done}} of the {{parts_total}} things people look for before they visit. The one still missing is {{next_label}}.' || E'\n\n'
   || '{{next_why}}' || E'\n\n'
   || '{{next_button}}: {{owner_url}}' || E'\n\n' || sigt || foott,
   20, false, '{}'::jsonb),

  ('tip-complete', 'Owner tip: page complete', 'lifecycle', true,
   '{{space_name}} has everything people look for',
   p || 'Hi {{first_name}},</p>' || E'\n'
   || p || 'Your page for {{space_name}} is complete. Photos, prices, opening hours, Wi-Fi speed and your own description are all there, so people can decide to come without having to ask first.</p>' || E'\n'
   || p || 'When something changes, like a new price or a new room, update it in your Owner account and it goes on your page.</p>' || E'\n'
   || '{{#is_free}}' || p || 'On Free, your first 2 requests from people come straight to you. Nomadwise Premium sends you every request, adds the Verified badge to your page and puts {{../space_name}} at the top of your region''s page. <a href="{{../premium_url}}" style="color:#FF444F;text-decoration:underline;">See what Premium adds</a></p>' || E'\n{{/is_free}}'
   || format(btn, '{{page_url}}', 'See my page') || E'\n' || sig || foot,
   'Hi {{first_name}},' || E'\n\n'
   || 'Your page for {{space_name}} is complete. Photos, prices, opening hours, Wi-Fi speed and your own description are all there, so people can decide to come without having to ask first.' || E'\n\n'
   || 'When something changes, like a new price or a new room, update it in your Owner account and it goes on your page.' || E'\n\n'
   || '{{#is_free}}On Free, your first 2 requests from people come straight to you. Nomadwise Premium sends you every request, adds the Verified badge to your page and puts {{../space_name}} at the top of your region''s page. See what Premium adds: {{../premium_url}}' || E'\n\n{{/is_free}}'
   || 'See my page: {{page_url}}' || E'\n\n' || sigt || foott,
   21, false, '{}'::jsonb),

  ('tip-quiet', 'Owner tip: since you last looked', 'lifecycle', true,
   '{{space_name}} since you last looked',
   p || 'Hi {{first_name}},</p>' || E'\n'
   || p || 'Here is what happened on your page for {{space_name}} since you last signed in on {{since_date}}.</p>' || E'\n'
   || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 20px;border:1px solid #E6E9ED;border-radius:8px;border-collapse:separate;">{{#each rows}}<tr><td style="padding:12px 16px;font-size:15px;color:#3D444D;{{border}}">{{label}}</td><td align="right" style="padding:12px 16px;font-size:17px;font-weight:700;color:#142032;{{border}}">{{value}}</td></tr>{{/each}}</table>' || E'\n'
   || '{{#has_next}}' || p || 'To turn more of these into visits, add {{../next_label}} next. {{../next_why}}</p>' || E'\n{{/has_next}}'
   || format(btn, '{{owner_url}}', 'Open my Owner account') || E'\n' || sig || foot,
   'Hi {{first_name}},' || E'\n\n'
   || 'Here is what happened on your page for {{space_name}} since you last signed in on {{since_date}}.' || E'\n\n'
   || '{{#each rows}}{{label}}: {{value}}' || E'\n' || '{{/each}}' || E'\n'
   || '{{#has_next}}To turn more of these into visits, add {{../next_label}} next. {{../next_why}}' || E'\n\n{{/has_next}}'
   || 'Open my Owner account: {{owner_url}}' || E'\n\n' || sigt || foott,
   22, false, '{}'::jsonb),

  ('tip-first-request', 'Owner tip: first request', 'lifecycle', true,
   'Your first request for {{space_name}}',
   p || 'Hi {{first_name}},</p>' || E'\n'
   || p || '{{space_name}} got its first request through Nomadwise {{when}}. Someone found your page and asked to come. Congratulations.</p>' || E'\n'
   || p || 'If you have not replied yet, their details are in the email we sent you. A quick reply is the best way to turn a request into a visit.</p>' || E'\n'
   || '{{#is_free}}' || p || 'On Free, your first 2 requests come straight to you. With Nomadwise Premium, every request does. <a href="{{../premium_url}}" style="color:#FF444F;text-decoration:underline;">See what Premium adds</a></p>' || E'\n{{/is_free}}'
   || '{{#has_next}}' || p || 'To get more requests like this one, add {{../next_label}} to your page next.</p>' || E'\n{{/has_next}}'
   || format(btn, '{{owner_url}}', 'Open my Owner account') || E'\n' || sig || foot,
   'Hi {{first_name}},' || E'\n\n'
   || '{{space_name}} got its first request through Nomadwise {{when}}. Someone found your page and asked to come. Congratulations.' || E'\n\n'
   || 'If you have not replied yet, their details are in the email we sent you. A quick reply is the best way to turn a request into a visit.' || E'\n\n'
   || '{{#is_free}}On Free, your first 2 requests come straight to you. With Nomadwise Premium, every request does. See what Premium adds: {{../premium_url}}' || E'\n\n{{/is_free}}'
   || '{{#has_next}}To get more requests like this one, add {{../next_label}} to your page next.' || E'\n\n{{/has_next}}'
   || 'Open my Owner account: {{owner_url}}' || E'\n\n' || sigt || foott,
   23, false, '{}'::jsonb)
  on conflict (alias) do nothing;
end $tpl$;

-- ---------- the words for the next thing to add ----------
create or replace function public.owner_tip_part(p_key text) returns jsonb
language sql immutable as $$
  select case p_key
    when 'prices' then jsonb_build_object('label', 'your prices', 'title', 'Add your prices', 'button', 'Add my prices',
      'why', 'With prices on your page, people pick a day pass, desk or meeting room and send you a request about it in one go. It is the quickest way to turn a page view into a request.')
    when 'photos' then jsonb_build_object('label', 'photos of your space', 'title', 'Add photos', 'button', 'Add photos',
      'why', 'Photos are the first thing people look at. Show your desks, the light and the coffee, so people can picture working there.')
    when 'description' then jsonb_build_object('label', 'your own description', 'title', 'Write your description', 'button', 'Write my description',
      'why', 'Tell people what makes your space different, the feel, who works there and what is close by.')
    when 'wifi' then jsonb_build_object('label', 'your Wi-Fi speed', 'title', 'Tell us your Wi-Fi speed', 'button', 'Send my Wi-Fi speed',
      'why', 'It is the first thing remote workers ask. Run a speed test at your space, send us the result and we add it to your page.')
    when 'hours' then jsonb_build_object('label', 'your opening hours', 'title', 'Add your opening hours', 'button', 'Add my opening hours',
      'why', 'So people know when they can come.')
  end;
$$;

-- ---------- one owner's model for one tip ----------
create or replace function public.owner_tip_model(p_venue uuid, p_kind text, p_email text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v      public.venues%rowtype;
  em     text;
  first  text;
  parts  jsonb;
  nx     jsonb;
  m      jsonb;
  last_seen timestamptz;
  since  date;
  g int; views int; dirs int; reqs int;
  rows   jsonb := '[]'::jsonb;
  fr     timestamptz;
  is_free boolean;
  tok    text;
begin
  select * into v from public.venues where id = p_venue;
  if not found then return null; end if;
  em := lower(btrim(coalesce(p_email, v.listing_owner_email)));
  first := coalesce(nullif(split_part(btrim(coalesce(v.listing_owner_name,
             (select lc.owner_name from public.listing_claims lc
               where lc.venue_id = v.id and lower(lc.owner_email) = em order by lc.created_at desc limit 1), '')), ' ', 1), ''), 'there');
  parts := public.page_parts(v.id);
  nx := public.owner_tip_part(parts ->> 'next');
  is_free := not (v.listing_tier = 'verified' and exists (
    select 1 from public.stripe_subscriptions s where s.subscription_id = v.stripe_subscription_id
       and s.status in ('active', 'trialing', 'past_due')));
  select token into tok from public.owner_email_prefs where email = em;
  m := jsonb_build_object(
    'first_name', first,
    'space_name', v.name,
    'page_url', coalesce(public.owner_page_url(v.id), 'https://www.nomadwise.io'),
    'owner_url', 'https://nomadmaps.io/owner?from=' || replace(p_kind, '_', '-'),
    'premium_url', 'https://nomadmaps.io/owner?from=' || replace(p_kind, '_', '-') || '-premium',
    'stop_url', 'https://nomadmaps.io/stop/?k=tips&t=' || coalesce(tok, 'test'),
    'is_free', is_free,
    'parts_done', parts ->> 'done', 'parts_total', parts ->> 'total',
    'has_next', nx is not null,
    'next_key', parts ->> 'next',
    'next_label', nx ->> 'label', 'next_title', nx ->> 'title',
    'next_button', nx ->> 'button', 'next_why', nx ->> 'why');

  if p_kind = 'tip_next' then
    m := m || jsonb_build_object('preview', (nx ->> 'title') || ' and your page has everything people look for.');
  elsif p_kind = 'tip_complete' then
    m := m || jsonb_build_object('preview', 'Photos, prices, opening hours, Wi-Fi and your own words, all on your page.');
  elsif p_kind = 'tip_quiet' then
    select greatest((select max(ov.last_at) from public.owner_visits ov where lower(ov.owner_email) = em),
                    (select max(od.submitted_at) from public.owner_drafts od where lower(od.owner_email) = em))
      into last_seen;
    since := coalesce(last_seen, now() - interval '30 days')::date;
    select coalesce(sum(impressions), 0) into g from public.page_google_days where venue_id = v.id and day >= since;
    select coalesce(sum(n) filter (where kind = 'view'), 0), coalesce(sum(n) filter (where kind = 'directions'), 0)
      into views, dirs from public.page_counts where venue_id = v.id and day >= since;
    select count(*) into reqs from public.enquiries where venue_id = v.id and status <> 'closed' and created_at >= since;
    -- only what there is; Google only from 20 (as the monthly email)
    if g >= 20 then rows := rows || jsonb_build_object('label', 'Shown in Google search', 'value', to_char(g, 'FM999,999')); end if;
    if views > 0 then rows := rows || jsonb_build_object('label', 'Page views', 'value', to_char(views, 'FM999,999')); end if;
    if dirs > 0 then rows := rows || jsonb_build_object('label', 'Asked for directions', 'value', to_char(dirs, 'FM999,999')); end if;
    if reqs > 0 then rows := rows || jsonb_build_object('label', case when reqs = 1 then 'Request' else 'Requests' end, 'value', reqs::text); end if;
    select jsonb_agg(r || jsonb_build_object('border', case when o > 1 then 'border-top:1px solid #E6E9ED;' else '' end) order by o)
      into rows from jsonb_array_elements(rows) with ordinality x(r, o);
    m := m || jsonb_build_object('since_date', trim(to_char(since, 'FMDD FMMonth')),
      'rows', coalesce(rows, '[]'::jsonb), 'worth_sending', jsonb_array_length(coalesce(rows, '[]'::jsonb)) > 0,
      'preview', coalesce((select string_agg(r ->> 'label' || ' ' || (r ->> 'value'), ', ' order by o)
                             from jsonb_array_elements(rows) with ordinality x(r, o)), '') || '.');
  elsif p_kind = 'tip_first_request' then
    select min(e.sent_at) into fr from public.enquiries e where e.venue_id = v.id and e.sent_at is not null;
    m := m || jsonb_build_object(
      'when', case when fr::date = current_date - 1 then 'yesterday'
                   when fr::date = current_date then 'today'
                   else 'on ' || trim(to_char(fr, 'FMDD FMMonth')) end,
      'preview', 'Someone found your page and asked to come.');
  end if;
  return m;
end $$;
revoke all on function public.owner_tip_model(uuid, text, text) from public, anon, authenticated;

-- ---------- who is due which tip today ----------
create or replace function public.owner_tips_due()
returns table (venue_id uuid, email text, kind text, tip_key text)
language plpgsql security definer set search_path to 'public' as $$
declare
  r     record;
  parts jsonb;
  st    public.owner_page_state%rowtype;
  live_at timestamptz;
  seen  timestamptz;
  k     text;
begin
  for r in
    select v.id, lower(btrim(v.listing_owner_email)) as em, v.name
      from public.venues v
     where coalesce(btrim(v.listing_owner_email), '') <> ''
       and v.website_status = 'released' and coalesce(v.webflow_slug, '') <> ''
       and lower(btrim(v.listing_owner_email)) not in (select e.email from public.owner_flow_team_emails e)
       and lower(btrim(v.listing_owner_email)) not like '%nomadwise%'
  loop
    parts := public.page_parts(r.id);
    select * into st from public.owner_page_state s where s.venue_id = r.id;
    k := null;

    -- 1. first request
    if not exists (select 1 from public.owner_emails o where o.venue_id = r.id and o.kind = 'tip_first_request')
       and exists (select 1 from public.enquiries e where e.venue_id = r.id and e.sent_at is not null)
       and (select min(e.sent_at) from public.enquiries e where e.venue_id = r.id and e.sent_at is not null)
           between now() - interval '7 days' and now() - interval '1 day' then
      k := 'tip_first_request';
    end if;

    -- 2. page complete (became complete since we last looked)
    if k is null and (parts ->> 'done')::int = (parts ->> 'total')::int
       and st.venue_id is not null and st.done < st.total
       and not exists (select 1 from public.owner_emails o where o.venue_id = r.id and o.kind = 'tip_complete') then
      k := 'tip_complete';
    end if;

    -- 3. the next thing, 3 to 21 days after something went live
    if k is null and parts ->> 'next' is not null then
      select greatest(
               (select max(od.reviewed_at) from public.owner_drafts od where od.venue_id = r.id and od.status = 'applied'),
               (select max(o.created_at) from public.owner_emails o where o.venue_id = r.id and o.kind = 'page_live' and o.status = 'sent'))
        into live_at;
      if live_at between now() - interval '21 days' and now() - interval '3 days'
         and not exists (select 1 from public.owner_emails o where o.venue_id = r.id and o.kind = 'tip_next'
                           and o.meta ->> 'tip_key' = parts ->> 'next') then
        k := 'tip_next';
      end if;
    end if;

    -- 4. gone quiet: signed in before, nothing for 30 days
    if k is null then
      select greatest((select max(ov.last_at) from public.owner_visits ov where lower(ov.owner_email) = r.em),
                      (select max(od.submitted_at) from public.owner_drafts od where lower(od.owner_email) = r.em))
        into seen;
      if seen is not null and seen < now() - interval '30 days'
         and not exists (select 1 from public.owner_emails o where o.venue_id = r.id and o.kind = 'tip_quiet'
                           and o.created_at > now() - interval '30 days')
         and coalesce((public.owner_tip_model(r.id, 'tip_quiet', r.em) ->> 'worth_sending')::boolean, false) then
        k := 'tip_quiet';
      end if;
    end if;

    if k is not null then
      venue_id := r.id; email := r.em; kind := k; tip_key := parts ->> 'next';
      return next;
    end if;
  end loop;
end $$;
revoke all on function public.owner_tips_due() from public, anon, authenticated;

-- ---------- the daily run ----------
create or replace function public.owner_tips_run(p_dry boolean default false) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  d     record;
  m     jsonb;
  sent  int := 0;
  held  int := 0;
  list  jsonb := '[]'::jsonb;
  names text[] := '{}';
  v_alias text;
  on_   boolean := coalesce((select (s.value ->> 'on')::boolean from public.sync_settings s where s.key = 'owner_tips'), false);
  r     record;
  parts jsonb;
begin
  for d in select * from public.owner_tips_due() loop
    -- the rules that hold a tip back today
    if extract(day from now() at time zone 'utc') <= 10
       or exists (select 1 from public.owner_emails o where lower(o.to_email) = d.email
                    and o.kind = 'monthly' and o.created_at > now() - interval '5 days')
       or exists (select 1 from public.owner_emails o where lower(o.to_email) = d.email
                    and o.kind like 'tip\_%' and o.created_at > now() - interval '7 days')
       or not public.owner_wants_email(d.email, 'tips') then
      held := held + 1;
      list := list || jsonb_build_object('venue', d.venue_id, 'kind', d.kind, 'held', true);
      continue;
    end if;
    v_alias := replace(d.kind, '_', '-');
    perform public.owner_email_token(d.email);
    m := public.owner_tip_model(d.venue_id, d.kind, d.email);
    list := list || jsonb_build_object('venue', d.venue_id, 'space', m ->> 'space_name', 'to', d.email, 'kind', d.kind);
    if p_dry or not on_ or not exists (select 1 from public.email_templates t where t.alias = v_alias and t.live) then
      continue;
    end if;
    begin
      perform public.pm_set_model(d.kind, v_alias, m);
      perform public.send_owner_email(d.email,
        case d.kind when 'tip_next' then 'One thing to add to ' when 'tip_complete' then 'Page complete: '
                    when 'tip_quiet' then 'Since you last looked: ' else 'Your first request for ' end || (m ->> 'space_name'),
        'Hi ' || (m ->> 'first_name') || E',\n\n' || coalesce(m ->> 'preview', ''),
        d.kind, d.venue_id::text, 'Open my Owner account', m ->> 'owner_url');
      update public.owner_emails o set meta = jsonb_build_object('tip_key', d.tip_key, 'tip', m ->> 'next_title')
       where o.id = (select o2.id from public.owner_emails o2 where o2.kind = d.kind and lower(o2.to_email) = d.email
                      order by o2.created_at desc limit 1);
      sent := sent + 1;
      names := names || ((m ->> 'space_name') || ' (' || replace(d.kind, 'tip_', '') || ')');
    exception when others then null;
    end;
  end loop;

  -- remember every live page's checklist, for "page complete" next time
  if not p_dry then
    for r in select v.id from public.venues v
              where coalesce(btrim(v.listing_owner_email), '') <> '' and v.website_status = 'released' loop
      parts := public.page_parts(r.id);
      insert into public.owner_page_state (venue_id, done, total, complete_at, checked_at)
      values (r.id, (parts ->> 'done')::int, (parts ->> 'total')::int,
              case when (parts ->> 'done') = (parts ->> 'total') then now() end, now())
      on conflict (venue_id) do update
        set done = excluded.done, total = excluded.total, checked_at = now(),
            complete_at = case when excluded.done = excluded.total
                               then coalesce(public.owner_page_state.complete_at, now()) end;
    end loop;
  end if;

  if sent > 0 then
    begin
      perform public.notify_phone('Owner tips sent',
        sent || case when sent = 1 then ' tip' else ' tips' end || ' went to owners: ' || array_to_string(names, ', ') || '.',
        'envelope');
    exception when others then null; end;
  end if;
  return jsonb_build_object('on', on_, 'dry', p_dry, 'sent', sent, 'held_by_rules', held, 'due', list);
end $$;
revoke all on function public.owner_tips_run(boolean) from public, anon, authenticated;

-- A test copy of one tip for one space, straight from the template
-- (live or not), to any address. Logged nowhere.
create or replace function public.owner_tip_test(p_to text, p_venue uuid, p_kind text, p_prefix text default '')
returns int language plpgsql security definer set search_path to 'public' as $$
declare
  m jsonb := public.owner_tip_model(p_venue, p_kind);
  t public.email_templates%rowtype;
  r record;
begin
  select * into t from public.email_templates where alias = replace(p_kind, '_', '-');
  select * into r from extensions.http(('POST', 'https://api.postmarkapp.com/email/withTemplate',
    array[extensions.http_header('X-Postmark-Server-Token', public.pm_token()), extensions.http_header('Accept', 'application/json')],
    'application/json',
    jsonb_build_object('From', 'Nomadwise Spaces <spaces@nomadwise.io>', 'To', p_to, 'ReplyTo', 'spaces@nomadwise.io',
      'TemplateAlias', t.alias, 'TemplateModel', jsonb_build_object('for_spaces', true) || m,
      'MessageStream', 'lifecycle', 'Tag', 'tip_test')::text)::extensions.http_request);
  return r.status;
end $$;
revoke all on function public.owner_tip_test(text, uuid, text, text) from public, anon, authenticated;

select cron.unschedule('owner-tips')
 where exists (select 1 from cron.job where jobname = 'owner-tips');
select cron.schedule('owner-tips', '47 9 * * *', 'select public.owner_tips_run()');

-- ---------- the Emails view counts them ----------
select public.pm_patch_fn('public.admin_email_flow(date)',
  $a$('plan_ended', 'plan_ended', 'Premium ended', 12)$a$,
  $a$('plan_ended', 'plan_ended', 'Premium ended', 12),
      ('tip_next', 'tip_next', 'Tip: the next thing to add', 13),
      ('tip_complete', 'tip_complete', 'Tip: page complete', 14),
      ('tip_quiet', 'tip_quiet', 'Tip: since you last looked', 15),
      ('tip_first_request', 'tip_first_request', 'Tip: first request', 16)$a$,
  $m$'tip_first_request', 'tip_first_request'$m$);
