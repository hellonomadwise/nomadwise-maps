-- Migration 358: opening hours and prices an owner saves go on the page
-- by themselves. Text, photos, tags, links and where requests go still
-- wait for one of us.
--
-- Jonathan, 24 Nov 2026, on the Owner flow's step "Auto-approve safe
-- fields. Wifi, hours and prices go live at once; only text and photos
-- wait for you": asked "Shall I build auto-approve for those three
-- now?", "yes". (He decides on coworking; no second sign-off.)
--
-- Wi-Fi was there already: a test done at the space goes straight on
-- (migration 262). This adds the other two.
--
-- What goes live by itself, and only when the owner pressed Save change
-- (never what was left unsent and sent for them after 15 minutes):
--   opening hours    when every day reads like hours (9:00 AM - 5:00 PM,
--                    Closed, Open 24 hours) and nothing looks unfinished;
--   the old day, week, month and cappuccino prices
--                    when each reads like a price (250,000 IDR, 2.50);
--   the price list   a removed price; a changed number within ten times
--                    the old one; a new price or new wording when the
--                    name and lines are ordinary (no links, no email
--                    addresses, no phone numbers, not long) and nothing
--                    looks unfinished.
-- Anything else in the same save waits as before, and so does anything
-- that fails a check above. One of us gets a phone notice either way.
--
-- Off switch: sync_settings 'owner_auto_live' {"on": false}.

insert into public.sync_settings (key, value)
values ('owner_auto_live', '{"on": true}'::jsonb)
on conflict (key) do nothing;

alter table public.owner_drafts
  add column if not exists auto_live    text[],
  add column if not exists auto_live_at timestamptz;
comment on column public.owner_drafts.auto_live is
  'What went on the page by itself from this draft (migration 358), e.g. {opening hours,prices}.';

-- 9:00 AM - 5:00 PM and 9:00am-5pm are the same hours.
create or replace function public.owner_hours_norm(p text)
returns text
language sql immutable
as $$
  select regexp_replace(translate(lower(coalesce(p, '')),
           chr(8211) || chr(8212) || chr(160) || chr(8239) || chr(8201), '--   '),
           '[\s-]+', '', 'g')
$$;

-- Every day reads like hours, and there is nothing but the seven days.
create or replace function public.owner_hours_ordinary(h jsonb)
returns boolean
language sql immutable
as $$
  select jsonb_typeof(h) = 'object'
     and not exists (
       select 1 from jsonb_each_text(h) e
        where e.key <> all (array['mon','tue','wed','thu','fri','sat','sun'])
           or (btrim(e.value) <> ''
               and btrim(translate(lower(e.value),
                     chr(8211) || chr(8212) || chr(160) || chr(8239) || chr(8201), '--   '))
                   !~ ('^(closed|open 24 hours|'
                       || '\d{1,2}(:\d{2})?\s*([ap]m)?\s*-\s*\d{1,2}(:\d{2})?\s*([ap]m)?'
                       || '(\s*,\s*\d{1,2}(:\d{2})?\s*([ap]m)?\s*-\s*\d{1,2}(:\d{2})?\s*([ap]m)?)*)$')))
     and exists (select 1 from jsonb_each_text(h) e where btrim(e.value) <> '')
$$;

-- A product's name, lines and shown price are ordinary: short, and no
-- link, email address or phone number in them.
create or replace function public.owner_text_ordinary(p jsonb)
returns boolean
language sql immutable
as $$
  select length(coalesce(p ->> 'name', '')) between 2 and 60
     and (coalesce(p ->> 'name', '') || ' ' || coalesce(p ->> 'label', ''))
           !~* '(https?:|www\.|@|\d{7,}|[a-z0-9-]\.(com|io|net|org|co|me|app|ly)\M)'
     and jsonb_array_length(case when jsonb_typeof(p -> 'details') = 'array'
                                 then p -> 'details' else '[]'::jsonb end) <= 8
     and not exists (
       select 1 from jsonb_array_elements_text(
                case when jsonb_typeof(p -> 'details') = 'array'
                     then p -> 'details' else '[]'::jsonb end) x
        where length(x) > 160
           or x ~* '(https?:|www\.|@|\d{7,}|[a-z0-9-]\.(com|io|net|org|co|me|app|ly)\M)')
$$;

-- The listing: what can go on the page by itself goes; the draft is
-- marked applied when nothing is left, and stays with us otherwise.
create or replace function public.owner_auto_live(p_draft uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  d      public.owner_drafts%rowtype;
  v      public.venues%rowtype;
  oc     jsonb;
  h      jsonb;
  own    jsonb;
  shown  jsonb;
  pr     jsonb;
  why    text[];
  live   text[] := '{}';
  rest   text;
  days   constant text[] := array['mon','tue','wed','thu','fri','sat','sun'];
begin
  if not coalesce((select (s.value ->> 'on')::boolean from public.sync_settings s
                    where s.key = 'owner_auto_live'), false) then
    return null;
  end if;
  select * into d from public.owner_drafts
   where id = p_draft and status = 'submitted' and discarded_at is null
     for update;
  if not found then return null; end if;
  select * into v from public.venues where id = d.venue_id;
  if not found then return null; end if;
  oc := coalesce(nullif(v.owner_content, 'null'::jsonb), '{}'::jsonb);
  why := coalesce(public.owner_draft_unfinished(d.venue_id, d.draft), '{}');

  -- opening hours: changed from what the page shows (their own, or
  -- Google's when they have none), and nothing odd about them
  h := d.draft -> 'hours';
  if jsonb_typeof(h) = 'object' and h <> '{}'::jsonb then
    own := case when jsonb_typeof(v.opening_hours) = 'object' then v.opening_hours else '{}'::jsonb end;
    shown := case when exists (select 1 from jsonb_each_text(own) e where btrim(e.value) <> '')
                  then own
                  else coalesce(public.owner_google_hours(v.g_details), '{}'::jsonb) end;
    if exists (select 1 from unnest(days) dd
                where public.owner_hours_norm(h ->> dd)
                      is distinct from public.owner_hours_norm(shown ->> dd))
       and public.owner_hours_ordinary(h)
       and not exists (select 1 from unnest(why) w
                        where w like 'the opening hours%' or w like 'a day opens%') then
      update public.venues
         set opening_hours = h,
             listing_sync_requested_at = now(), listing_synced_at = null,
             listing_sync_error = null
       where id = v.id;
      live := live || 'opening hours'::text;
    end if;
  end if;

  -- the old day, week and month prices and the cappuccino
  pr := d.draft -> 'prices';
  if jsonb_typeof(pr) = 'object'
     and exists (select 1 from unnest(array['day','week','month','coffee']) pp
                  where btrim(coalesce(pr ->> pp, ''))
                        is distinct from btrim(coalesce(oc -> 'prices' ->> pp, '')))
     and not exists (select 1 from unnest(array['day','week','month','coffee']) pp
                      where btrim(coalesce(pr ->> pp, '')) <> ''
                        and (length(btrim(pr ->> pp)) > 30
                             or btrim(pr ->> pp) !~ ('^([A-Za-z]{3}|[^\w\s]{1,3})?\s*\d{1,3}(([.,\s]\d{3})*|\d*)'
                                                     || '([.,]\d{1,2})?\s*([A-Za-z]{3}|[^\w\s]{1,3})?$')))
     and not ('a price is zero' = any (why)) then
    update public.venues
       set owner_content = oc || jsonb_build_object('prices', pr),
           owner_content_at = now(),
           listing_sync_requested_at = now(), listing_synced_at = null,
           listing_sync_error = null
     where id = v.id;
    live := live || 'prices'::text;
  end if;

  if coalesce(array_length(live, 1), 0) = 0 then
    -- Only a price list was saved, and it went on by itself a moment
    -- ago: nothing here is left for us to read.
    if public.owner_draft_changes(d.venue_id, d.draft) is null
       and exists (select 1 from public.product_changes x
                    where x.venue_id = d.venue_id and x.source = 'owner'
                      and x.decided_by = 'by itself (owner saved)'
                      and x.decided_at > now() - interval '5 minutes') then
      update public.owner_drafts
         set status = 'applied', reviewed_at = now(), updated_at = now(),
             auto_live = array['prices'], auto_live_at = now()
       where id = d.id;
      return jsonb_build_object('live', jsonb_build_array('prices'), 'rest', null,
                                'status', 'applied');
    end if;
    return null;
  end if;

  -- what is still for us to read (the page now holds the parts above)
  rest := public.owner_draft_changes(d.venue_id, d.draft);
  if rest is null then
    update public.owner_drafts
       set status = 'applied', reviewed_at = now(), updated_at = now(),
           auto_live = live, auto_live_at = now()
     where id = d.id;
  else
    update public.owner_drafts
       set auto_live = live, auto_live_at = now()
     where id = d.id;
  end if;

  perform public.notify_phone(
    'Went on the page by itself',
    coalesce(v.name, 'A space') || ': ' || array_to_string(live, ' and ')
      || ', saved by the owner.'
      || case when rest is not null
              then ' Still for you to read in Owner changes: ' || rest || '.' else '' end,
    'zap');

  return jsonb_build_object('live', to_jsonb(live), 'rest', rest,
                            'status', case when rest is null then 'applied' else 'submitted' end);
end $$;
revoke all on function public.owner_auto_live(uuid) from public, anon, authenticated;

-- The price list: each of the owner's waiting changes that is ordinary
-- is approved as a Go in Prices would approve it.
create or replace function public.owner_prices_auto_live(p_venue uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  c      public.product_changes%rowtype;
  fin    jsonb;
  ok     boolean;
  a      numeric;
  b      numeric;
  n_live integer := 0;
  n_wait integer := 0;
  v_name text;
begin
  if not coalesce((select (s.value ->> 'on')::boolean from public.sync_settings s
                    where s.key = 'owner_auto_live'), false) then
    return null;
  end if;
  -- left unsent and sent for them: one of us reads it first
  if coalesce(current_setting('nomadwise.unsent', true), '') = '1' then
    return null;
  end if;
  if coalesce(array_length(public.owner_prices_unfinished(p_venue, p_rows), 1), 0) > 0 then
    return null;
  end if;

  for c in
    select * from public.product_changes x
     where x.venue_id = p_venue and x.source = 'owner' and x.status = 'proposed'
     order by x.created_at
       for update
  loop
    ok := true;
    fin := null;
    if c.action <> 'remove' then
      fin := coalesce(c.final, c.proposed);
      if fin is not null and c.action = 'add' and not (fin ? 'problem') then
        fin := fin || jsonb_build_object('starting_from', false);
      end if;
      ok := fin is not null and public.product_problem(fin) is null;
      -- new wording is looked at; a number alone is not
      if ok and (c.action = 'add'
                 or coalesce(fin ->> 'name', '') is distinct from coalesce(c.before ->> 'name', '')
                 or coalesce(fin ->> 'label', '') is distinct from coalesce(c.before ->> 'label', '')
                 or coalesce(fin -> 'details', '[]'::jsonb)
                    is distinct from coalesce(c.before -> 'details', '[]'::jsonb)) then
        ok := public.owner_text_ordinary(fin);
      end if;
      -- more than ten times the old price, or under a tenth: a slip
      if ok and c.action = 'update'
         and jsonb_typeof(fin -> 'amount') = 'number'
         and jsonb_typeof(c.before -> 'amount') = 'number' then
        a := (fin ->> 'amount')::numeric;
        b := (c.before ->> 'amount')::numeric;
        if b > 0 and (a > b * 10 or a < b / 10) then
          ok := false;
        end if;
      end if;
    end if;
    if ok then
      update public.product_changes
         set status = 'approved', final = fin, error = null, claimed_at = null,
             decided_at = clock_timestamp(), decided_by = 'by itself (owner saved)'
       where id = c.id;
      n_live := n_live + 1;
    else
      n_wait := n_wait + 1;
    end if;
  end loop;

  if n_live > 0 then
    perform public.upgrades_nudge();
    select name into v_name from public.venues where id = p_venue;
    perform public.notify_phone(
      'Went on the page by itself',
      coalesce(v_name, 'A space') || ': ' || n_live
        || case when n_live = 1 then ' price change' else ' price changes' end
        || ', saved by the owner.'
        || case when n_wait > 0
                then ' ' || n_wait || ' more for you to check in Prices.' else '' end,
      'zap');
  end if;
  return jsonb_build_object('live', n_live, 'waiting', n_wait);
end $$;
revoke all on function public.owner_prices_auto_live(uuid, jsonb) from public, anon, authenticated;

-- Save change on the listing: what can go live goes; the phone notice
-- "to review" is only for what is left.
select public.pm_patch_fn('public.owner_save_draft(uuid,jsonb,boolean)',
  $a$  clean  jsonb;
begin$a$,
  $a$  clean  jsonb;
  auto   jsonb;
begin$a$,
  $a$auto   jsonb;$a$);

select public.pm_patch_fn('public.owner_save_draft(uuid,jsonb,boolean)',
  $a$  if p_submit then
    perform public.notify_phone(
      'Owner changes to review',$a$,
  $a$  if p_submit then
    begin
      auto := public.owner_auto_live(d.id);
    exception when others then
      auto := null;
    end;
  end if;

  if p_submit and (auto is null or auto ->> 'rest' is not null) then
    perform public.notify_phone(
      'Owner changes to review',$a$,
  $a$public.owner_auto_live(d.id)$a$);

select public.pm_patch_fn('public.owner_save_draft(uuid,jsonb,boolean)',
  $a$  return jsonb_build_object('id', d.id, 'status', d.status,
                            'submitted_at', d.submitted_at);$a$,
  $a$  return jsonb_build_object('id', d.id, 'status', coalesce(auto ->> 'status', d.status),
                            'submitted_at', d.submitted_at,
                            'live', coalesce(auto -> 'live', '[]'::jsonb),
                            'waiting', auto -> 'rest');$a$,
  $a$'waiting', auto -> 'rest'$a$);

-- Save change on the price list.
select public.pm_patch_fn('public.owner_propose_products(uuid,jsonb,text)',
  $a$  problems jsonb := '[]'::jsonb;
begin$a$,
  $a$  problems jsonb := '[]'::jsonb;
  auto     jsonb;
begin$a$,
  $a$auto     jsonb;$a$);

select public.pm_patch_fn('public.owner_propose_products(uuid,jsonb,text)',
  $a$  return jsonb_build_object('added', n_add, 'changed', n_up, 'removed', n_rm,
                            'problems', problems);$a$,
  $a$  if jsonb_array_length(problems) = 0 then
    begin
      auto := public.owner_prices_auto_live(v.id, p_rows);
    exception when others then
      auto := null;
    end;
  end if;

  return jsonb_build_object('added', n_add, 'changed', n_up, 'removed', n_rm,
                            'problems', problems,
                            'live', coalesce((auto ->> 'live')::integer, 0),
                            'waiting', coalesce((auto ->> 'waiting')::integer, n_add + n_up + n_rm));$a$,
  $a$public.owner_prices_auto_live(v.id, p_rows)$a$);

-- A price list left unsent is sent for them, and says so, so it waits
-- for one of us as before.
select public.pm_patch_fn('public.owner_autosend_run(boolean)',
  $a$        res := public.owner_propose_products(p.venue_id, p.price_rows, p.currency);$a$,
  $a$        perform set_config('nomadwise.unsent', '1', true);
        res := public.owner_propose_products(p.venue_id, p.price_rows, p.currency);$a$,
  $a$'nomadwise.unsent', '1'$a$);

select public.pm_patch_fn('public.owner_autosend_run(boolean)',
  $a$      perform set_config('request.jwt.claims', '', true);$a$,
  $a$      perform set_config('request.jwt.claims', '', true);
      perform set_config('nomadwise.unsent', '', true);$a$,
  $a$'nomadwise.unsent', ''$a$);

-- The Owner account is told which parts went on by themselves.
select public.pm_patch_fn('public.owner_venues()',
  $a$'held', to_jsonb(d.held), 'auto_sent', d.auto_sent,$a$,
  $a$'held', to_jsonb(d.held), 'auto_sent', d.auto_sent,
                  'auto_live', to_jsonb(d.auto_live),$a$,
  $a$'auto_live', to_jsonb(d.auto_live)$a$);

-- The Owner flow's "build it" ask for this is done.
update public.owner_flow_asks
   set done_at = now(),
       note = coalesce(note || '; ', '') || 'built 24 Nov 2026 on Jonathan''s word (migration 358)'
 where item = 'Auto-approve safe fields (wifi, hours, prices)' and done_at is null;

-- A new price that went on by itself is "approved" for the few minutes
-- until the page is written. Saved again in that time it must not be
-- sent twice: the same price is left alone, a changed one takes the
-- place of the one on its way (or, once the page is being written,
-- says so).
select public.pm_patch_fn('public.owner_propose_products(uuid,jsonb,text)',
  $a$      seen := seen || lower(fin->>'name');
      insert into public.product_changes
        (venue_id, action, proposed, final, note, source)$a$,
  $a$      seen := seen || lower(fin->>'name');
      select * into open_ from public.product_changes x
       where x.venue_id = v.id and x.source = 'owner' and x.action = 'add'
         and x.status = 'approved'
         and lower(x.final ->> 'name') = lower(fin ->> 'name')
       limit 1;
      if found then
        if (open_.final - 'starting_from') is distinct from (fin - 'starting_from') then
          if open_.claimed_at is null then
            -- back to waiting: it is looked at again below, and goes
            -- on by itself once more when it is ordinary
            update public.product_changes
               set status = 'proposed', proposed = fin, final = fin,
                   decided_at = null, decided_by = null
             where id = open_.id;
          else
            problems := problems || jsonb_build_array(jsonb_build_object(
              'name', coalesce(r->>'name', ''),
              'why', 'a change to this price is already on its way to your page'));
          end if;
        end if;
        continue;
      end if;
      insert into public.product_changes
        (venue_id, action, proposed, final, note, source)$a$,
  $a$and x.status = 'approved'
         and lower(x.final ->> 'name') = lower(fin ->> 'name')$a$);

-- The Owner account tells "waiting for us" from "on its way to the page".
select public.pm_patch_fn('public.owner_page_extras(venues)',
  $a$          and c.status in ('proposed', 'approved', 'failed')),$a$,
  $a$          and c.status in ('proposed', 'failed')),
    'price_changes_coming', (select count(*) from public.product_changes c
        where c.venue_id = v.id and c.source = 'owner'
          and c.status = 'approved'),$a$,
  $a$'price_changes_coming'$a$);
