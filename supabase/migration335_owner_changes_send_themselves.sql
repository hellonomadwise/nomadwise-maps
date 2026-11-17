-- Migration 335: what an owner types is never lost, and reaches us
-- without a second press, unless it looks unfinished.
--
-- Jonathan, 17 Nov 2026: "an owner can save changes but they have to
-- press send? really?", "i like the idea of auto save though. But, if
-- you can somehow create a detection for something incompleted", and
-- "ultimately its all about their experience, to make it as easy as
-- possible".
--
-- Until now the Owner account kept what was typed as a draft, and the
-- draft only came to us on "Save change". An owner who left without
-- that press had an unsent draft and nothing more happened. The price
-- list was not kept at all: leaving the price editor lost it.
--
-- Now:
-- 1. The price list is kept as it is typed (owner_price_drafts).
-- 2. Fifteen quiet minutes after the last edit, what was left unsent
--    is looked at (owner_autosend_run, every five minutes):
--      looks finished    it is sent for review, marked "sent
--                        automatically"; the phone is told as for any
--                        owner change
--      looks unfinished  it is held, with why (owner_drafts.held), and
--                        the Owner account says so with Send and
--                        Discard; one email a day later if still there
-- 3. Discard (owner_discard_changes): back to the page as it is live.
--    The unsent draft is set aside (owner_drafts.discarded_at), not
--    removed: what an owner dropped can still be read.
-- 4. Changes sent automatically and then undone by the owner (Cancel)
--    are taken back out of our queue.
--
-- Nothing goes on a page without one of us approving it, as before.

alter table public.owner_drafts
  add column if not exists held text[],
  add column if not exists checked_at timestamptz,
  add column if not exists auto_sent boolean not null default false,
  add column if not exists reminded_at timestamptz,
  add column if not exists discarded_at timestamptz;
comment on column public.owner_drafts.discarded_at is
  'The owner pressed Discard on this unsent draft. It is kept, set aside: nothing reads it as their draft any more. Migration 335.';
comment on column public.owner_drafts.held is
  'Why an unsent draft was not sent automatically: it looks unfinished. Emptied by the next save. Migration 335.';
comment on column public.owner_drafts.auto_sent is
  'Sent for review by the clock, not by the owner pressing Save change. Migration 335.';

create table if not exists public.owner_price_drafts (
  venue_id    uuid primary key references public.venues(id) on delete cascade,
  owner_email text not null,
  price_rows  jsonb not null default '[]'::jsonb,
  currency    text,
  updated_at  timestamptz not null default now(),
  held        text[],
  checked_at  timestamptz,
  reminded_at timestamptz
);
comment on table public.owner_price_drafts is
  'An owner''s price list as typed and not sent yet (the rows of the price editor). Gone once sent or discarded. Migration 335.';
alter table public.owner_price_drafts enable row level security;
revoke all on table public.owner_price_drafts from public, anon, authenticated;

-- ------------------------------------------------ the price list, kept
create or replace function public.owner_save_price_draft(
  p_venue uuid, p_rows jsonb, p_currency text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  em text := public.owner_email();
begin
  if em is null then
    raise exception 'Please sign in.';
  end if;
  perform 1 from public.venues
   where id = p_venue and lower(coalesce(listing_owner_email, '')) = em;
  if not found then
    raise exception 'This space is not on your account.';
  end if;
  -- nothing to keep: put back as on the page
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    delete from public.owner_price_drafts where venue_id = p_venue;
    return jsonb_build_object('saved', false);
  end if;
  if jsonb_array_length(p_rows) > 40 or pg_column_size(p_rows) > 60000 then
    raise exception 'Up to 40 prices, please.';
  end if;
  insert into public.owner_price_drafts
    (venue_id, owner_email, price_rows, currency, updated_at, held, checked_at)
  values (p_venue, em, p_rows,
          nullif(upper(btrim(coalesce(p_currency, ''))), ''), now(), null, null)
  on conflict (venue_id) do update
    set owner_email = excluded.owner_email,
        price_rows = excluded.price_rows,
        currency = excluded.currency,
        updated_at = now(),
        held = null,
        checked_at = null;
  return jsonb_build_object('saved', true);
end $function$;
revoke all on function public.owner_save_price_draft(uuid, jsonb, text) from public, anon;
grant execute on function public.owner_save_price_draft(uuid, jsonb, text) to authenticated, service_role;

-- ------------------------------------------------ what changed, the listing only
-- owner_draft_changes also counts the price changes already with us;
-- those are not "unsent".
create or replace function public.owner_draft_changes_own(p_venue uuid, p_draft jsonb)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select nullif(btrim(regexp_replace(
           coalesce(public.owner_draft_changes(p_venue, p_draft), ''),
           '(^|, )price list \(\d+ changes?\)$', '')), '');
$$;
revoke all on function public.owner_draft_changes_own(uuid, jsonb) from public, anon, authenticated;

-- The description box opens with the page's own words, which for some
-- pages are only in venue_page_facts: an untouched box is not "new".
select public.pm_patch_fn('public.owner_draft_changes(uuid,jsonb)',
  $a$  b := btrim(coalesce(nullif(oc ->> 'description', ''), v ->> 'page_description', ''));$a$,
  $a$  b := btrim(coalesce(nullif(oc ->> 'description', ''),
                      nullif(btrim(v ->> 'page_description'), ''),
                      (select f.facts ->> 'desc' from public.venue_page_facts f
                        where f.venue_id = p_venue limit 1), ''));$a$,
  $a$venue_page_facts$a$);

-- A Premium message's button and link count as a change, and so does
-- taking the message off: before, neither was seen, so such a draft
-- would have read as "the same as the page".
select public.pm_patch_fn('public.owner_draft_changes(uuid,jsonb)',
  $a$          or btrim(coalesce(d -> 'mention' ->> 'body', ''))
            is distinct from btrim(coalesce(oc -> 'mention' ->> 'body', ''))) then
    parts := parts || 'Premium message'::text;
  end if;$a$,
  $a$          or btrim(coalesce(d -> 'mention' ->> 'body', ''))
            is distinct from btrim(coalesce(oc -> 'mention' ->> 'body', ''))
          or btrim(coalesce(d -> 'mention' ->> 'cta', ''))
            is distinct from btrim(coalesce(oc -> 'mention' ->> 'cta', ''))
          or btrim(coalesce(d -> 'mention' ->> 'url', ''))
            is distinct from btrim(coalesce(oc -> 'mention' ->> 'url', ''))) then
    parts := parts || 'Premium message'::text;
  elsif d ? 'mention'
        and btrim(coalesce(d -> 'mention' ->> 'title', '')) = ''
        and btrim(coalesce(oc -> 'mention' ->> 'title', '')) <> '' then
    parts := parts || 'Premium message removed'::text;
  end if;$a$,
  $a$Premium message removed$a$);

-- ------------------------------------------------ does it look unfinished?
-- Only what was changed is looked at: something odd that is already on
-- the page does not hold a change to another part. The words are for
-- the owner ("... looks unfinished: the description is very short").
create or replace function public.owner_draft_unfinished(p_venue uuid, p_draft jsonb)
returns text[]
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v      jsonb;
  oc     jsonb;
  d      jsonb := coalesce(p_draft, '{}'::jsonb);
  why    text[] := '{}';
  a      text;
  b      text;
  raw    text;
  live   jsonb;
  blank  text[];
  n_set  integer;
  n_live integer;
  days   constant text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  names  constant jsonb := '{"mon":"Monday","tue":"Tuesday","wed":"Wednesday",
    "thu":"Thursday","fri":"Friday","sat":"Saturday","sun":"Sunday"}';
begin
  select to_jsonb(x) into v from public.venues x where x.id = p_venue;
  if v is null then return why; end if;
  oc := coalesce(nullif(v -> 'owner_content', 'null'::jsonb), '{}'::jsonb);

  -- the description
  a := btrim(coalesce(d ->> 'description', ''));
  b := btrim(coalesce(nullif(oc ->> 'description', ''),
                      nullif(btrim(v ->> 'page_description'), ''),
                      (select f.facts ->> 'desc' from public.venue_page_facts f
                        where f.venue_id = p_venue limit 1), ''));
  if a <> b then
    if a = '' then
      why := why || 'the description is empty'::text;
    elsif length(a) < 40 then
      why := why || 'the description is very short'::text;
    elsif length(b) >= 200 and length(a) < length(b) * 0.5 then
      why := why || 'the description is much shorter than before'::text;
    elsif a ~ ('[,;:(/&+' || chr(8211) || chr(8212) || '-]$')
       or a ~* '\m(and|or|the|a|an|to|of|with|in|for|our|we|is|are|at|on|from|by|your|as|but|that|which)$' then
      why := why || 'the description seems to stop mid-sentence'::text;
    end if;
  end if;

  -- opening hours (an empty set means "not touched")
  if jsonb_typeof(d -> 'hours') = 'object' and (d -> 'hours') <> '{}'::jsonb then
    live := coalesce(nullif(v -> 'opening_hours', 'null'::jsonb), '{}'::jsonb);
    if jsonb_typeof(live) <> 'object' then
      live := '{}'::jsonb;
    end if;
    if not exists (select 1 from jsonb_each_text(live) e where btrim(e.value) <> '') then
      -- none of their own: the form opened with Google's
      live := coalesce(public.owner_google_hours(v -> 'g_details'), '{}'::jsonb);
    end if;
    if exists (
      select 1 from unnest(days) dd
       where regexp_replace(translate(lower(coalesce(d -> 'hours' ->> dd, '')),
               chr(8211) || chr(8212) || chr(160) || chr(8239) || chr(8201), '--   '),
               '[\s-]+', '', 'g')
             is distinct from
             regexp_replace(translate(lower(coalesce(live ->> dd, '')),
               chr(8211) || chr(8212) || chr(160) || chr(8239) || chr(8201), '--   '),
               '[\s-]+', '', 'g')) then
      select count(*) filter (where btrim(coalesce(d -> 'hours' ->> dd, '')) <> ''),
             count(*) filter (where btrim(coalesce(live ->> dd, '')) <> '')
        into n_set, n_live
        from unnest(days) dd;
      -- a day left "Not set" that had hours before, or a first set of
      -- hours with days missing
      select array_agg(names ->> t.dd order by t.ord) into blank
        from unnest(days) with ordinality as t(dd, ord)
       where btrim(coalesce(d -> 'hours' ->> t.dd, '')) = ''
         and (btrim(coalesce(live ->> t.dd, '')) <> '' or n_live = 0);
      if n_set > 0 and coalesce(array_length(blank, 1), 0) > 0 then
        why := why || ('the opening hours are not set for '
                || array_to_string(blank, ', ')
                || ' (choose Closed for a day you are closed)');
      end if;
      -- opens and closes at the same time
      if exists (
        select 1 from unnest(days) dd,
               lateral (select regexp_match(
                 translate(lower(coalesce(d -> 'hours' ->> dd, '')), chr(8211) || chr(8212), '--'),
                 '^\s*(\d{1,2}:\d{2})\s*([ap]m)\s*-\s*(\d{1,2}:\d{2})\s*([ap]m)\s*$') as m) x
         where x.m is not null and x.m[1] = x.m[3] and x.m[2] = x.m[4]) then
        why := why || 'a day opens and closes at the same time'::text;
      end if;
    end if;
  end if;

  -- the old day, week and month prices and the coffee
  if exists (
    select 1 from unnest(array['day','week','month','coffee']) pp
     where btrim(coalesce(d -> 'prices' ->> pp, ''))
           is distinct from btrim(coalesce(oc -> 'prices' ->> pp, ''))
       and btrim(coalesce(d -> 'prices' ->> pp, '')) ~ '\d'
       and btrim(coalesce(d -> 'prices' ->> pp, '')) ~ '^\D*0+([.,]0+)?\D*$') then
    why := why || 'a price is zero'::text;
  end if;

  -- links
  a := btrim(coalesce(d ->> 'website', ''));
  b := btrim(coalesce(v ->> 'website', ''));
  if a <> '' and lower(regexp_replace(a, '/+$', '')) <> lower(regexp_replace(b, '/+$', ''))
     and a !~* '^(https?://)?([a-z0-9-]+\.)+[a-z]{2,}(:\d+)?([/?#]\S*)?$' then
    why := why || 'the website address does not look right'::text;
  end if;

  raw := btrim(coalesce(d ->> 'instagram', ''));
  a := lower(regexp_replace(regexp_replace(raw,
         '^(https?://)?(www\.)?instagram\.com/', '', 'i'), '^@|[/?].*$', '', 'g'));
  b := lower(regexp_replace(regexp_replace(btrim(coalesce(v ->> 'instagram', '')),
         '^(https?://)?(www\.)?instagram\.com/', '', 'i'), '^@|[/?].*$', '', 'g'));
  if raw <> '' and a <> b and a !~ '^[a-z0-9._]{1,30}$' then
    why := why || 'the Instagram name does not look right'::text;
  end if;

  a := regexp_replace(coalesce(d ->> 'whatsapp', ''), '[^0-9]', '', 'g');
  b := regexp_replace(coalesce(oc ->> 'whatsapp', ''), '[^0-9]', '', 'g');
  if a <> '' and a <> b and (length(a) < 8 or length(a) > 15) then
    why := why || 'the WhatsApp number does not look complete'::text;
  end if;

  a := lower(btrim(coalesce(d ->> 'enquiry_email', '')));
  b := lower(btrim(coalesce(v ->> 'listing_enquiry_email', '')));
  if a <> '' and a <> b and a !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    why := why || 'the email address for requests does not look right'::text;
  end if;

  -- the Premium message: a title and its text go together
  a := btrim(coalesce(d -> 'mention' ->> 'title', ''));
  b := btrim(coalesce(d -> 'mention' ->> 'body', ''));
  if (a is distinct from btrim(coalesce(oc -> 'mention' ->> 'title', ''))
      or b is distinct from btrim(coalesce(oc -> 'mention' ->> 'body', ''))) then
    if a <> '' and b = '' then
      why := why || 'your Premium message has a title and no text'::text;
    elsif a = '' and b <> '' then
      why := why || 'your Premium message has text and no title'::text;
    end if;
  end if;

  return why;
exception when others then
  -- a check that cannot be made holds nothing back
  return '{}';
end $function$;
revoke all on function public.owner_draft_unfinished(uuid, jsonb) from public, anon, authenticated;

-- The price list. "Price on request" (no amount) is a finished price.
-- "Per what" is only asked of a new price: one already on the page
-- without it is not what the owner was changing.
create or replace function public.owner_prices_unfinished(p_venue uuid, p_rows jsonb)
returns text[]
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  r    jsonb;
  nm   text;
  amt  text;
  why  text[] := '{}';
  n    integer := 0;
begin
  for r in select value from jsonb_array_elements(
             case when jsonb_typeof(p_rows) = 'array' then p_rows else '[]'::jsonb end) loop
    if jsonb_typeof(r) <> 'object' then continue; end if;
    n := n + 1;
    nm := btrim(coalesce(r ->> 'name', ''));
    amt := btrim(coalesce(r ->> 'amount', ''));
    if length(nm) < 2 then
      if not ('a price has no name' = any (why)) then
        why := why || 'a price has no name'::text;
      end if;
    elsif amt ~ '^0+([.,]0+)?$' then
      why := why || ('"' || nm || '" has a price of zero');
    elsif amt <> '' and amt !~ '^\d+([.,]\d+)?$' then
      why := why || ('the price of "' || nm || '" could not be read');
    elsif amt <> '' and coalesce(r ->> 'id', '') = ''
          and coalesce(r ->> 'category', 'coworking') <> 'other'
          and not exists (
            select 1 from jsonb_array_elements_text(
                     case when jsonb_typeof(r -> 'details') = 'array'
                          then r -> 'details' else '[]'::jsonb end) x
             where btrim(x) ~* '^(price )?per (hour|day|week|month|year)\.?$')
          and lower(nm) !~ '\m\d+[ -]?(hours?|days?|weeks?|months?|visits?|entries|passes|credits?)\M' then
      why := why || ('"' || nm || '" does not say per hour, day, week or month');
    end if;
  end loop;
  if n = 0 and exists (select 1 from public.venue_products x
                        where x.venue_id = p_venue and x.status = 'live') then
    why := why || 'the price list is empty'::text;
  end if;
  return why;
exception when others then
  return '{}';
end $function$;
revoke all on function public.owner_prices_unfinished(uuid, jsonb) from public, anon, authenticated;

-- ------------------------------------------------ discard
create or replace function public.owner_discard_changes(p_venue uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  em text := public.owner_email();
  n  integer;
begin
  if em is null then
    raise exception 'Please sign in.';
  end if;
  perform 1 from public.venues
   where id = p_venue and lower(coalesce(listing_owner_email, '')) = em;
  if not found then
    raise exception 'This space is not on your account.';
  end if;
  -- Only what was never sent: what is with us for review stays. Set
  -- aside, not removed, so what an owner dropped can still be read.
  update public.owner_drafts
     set discarded_at = now(), held = null
   where venue_id = p_venue and status = 'draft' and discarded_at is null;
  get diagnostics n = row_count;
  -- the price list as typed goes the same way (null: nothing kept)
  perform public.owner_save_price_draft(p_venue, null, null);
  return jsonb_build_object('listing', n);
end $function$;
revoke all on function public.owner_discard_changes(uuid) from public, anon;
grant execute on function public.owner_discard_changes(uuid) to authenticated, service_role;

-- ------------------------------------------------ the clock
-- p_dry: say what would happen, change nothing, send nothing.
create or replace function public.owner_autosend_run(p_dry boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  quiet   constant interval := interval '15 minutes';
  d       public.owner_drafts%rowtype;
  p       public.owner_price_drafts%rowtype;
  r       record;
  v_name  text;
  diff    text;
  why     text[];
  res     jsonb;
  n       integer;
  first   text;
  acct    text;
  body    text;
  sent    jsonb := '[]'::jsonb;
  held_   jsonb := '[]'::jsonb;
  back    jsonb := '[]'::jsonb;
  mailed  jsonb := '[]'::jsonb;
begin
  -- 1. listings left unsent
  for d in
    select * from public.owner_drafts x
     where x.status = 'draft' and x.discarded_at is null
       and x.updated_at < now() - quiet
       and (x.checked_at is null or x.checked_at < x.updated_at)
     order by x.updated_at
  loop
    select name into v_name from public.venues where id = d.venue_id;
    diff := public.owner_draft_changes_own(d.venue_id, d.draft);
    why := public.owner_draft_unfinished(d.venue_id, d.draft);
    if diff is null and coalesce(array_length(why, 1), 0) = 0 then
      -- the same as the page: nothing to send
      if not p_dry then
        update public.owner_drafts set checked_at = now(), held = null where id = d.id;
      end if;
      continue;
    end if;
    if coalesce(array_length(why, 1), 0) > 0 then
      held_ := held_ || jsonb_build_object('space', v_name, 'what', 'listing', 'why', to_jsonb(why));
      if not p_dry then
        update public.owner_drafts set held = why, checked_at = now() where id = d.id;
      end if;
      continue;
    end if;
    sent := sent || jsonb_build_object('space', v_name, 'what', 'listing', 'changes', diff);
    if not p_dry then
      update public.owner_drafts
         set status = 'submitted', submitted_at = now(), auto_sent = true,
             held = null, checked_at = now()
       where id = d.id;
      perform public.notify_phone(
        'Owner changes to review',
        coalesce(v_name, 'A space') || ': ' || diff
          || '. Sent automatically: the owner left without pressing Save change. '
          || 'Review in Owner changes.',
        'pencil');
    end if;
  end loop;

  -- 2. sent automatically, then undone by the owner (Cancel): nothing
  --    is left to review, so it leaves our queue
  for d in
    select * from public.owner_drafts x
     where x.status = 'submitted' and x.auto_sent
       and x.updated_at > x.submitted_at
       and x.updated_at < now() - quiet
       and (x.checked_at is null or x.checked_at < x.updated_at)
  loop
    select name into v_name from public.venues where id = d.venue_id;
    if public.owner_draft_changes(d.venue_id, d.draft) is null then
      back := back || jsonb_build_object('space', v_name);
      if not p_dry then
        update public.owner_drafts
           set status = 'draft', submitted_at = null, auto_sent = false,
               held = null, checked_at = now()
         where id = d.id;
        perform public.notify_phone(
          'Owner changes taken back',
          coalesce(v_name, 'A space') || ': the changes that were sent automatically '
            || 'were undone by the owner. Nothing to review.',
          'leftwards_arrow_with_hook');
      end if;
    elsif not p_dry then
      update public.owner_drafts set checked_at = now() where id = d.id;
    end if;
  end loop;

  -- 3. price lists left unsent
  for p in
    select * from public.owner_price_drafts x
     where x.updated_at < now() - quiet
       and (x.checked_at is null or x.checked_at < x.updated_at)
     order by x.updated_at
  loop
    select name into v_name from public.venues where id = p.venue_id;
    why := public.owner_prices_unfinished(p.venue_id, p.price_rows);
    res := null;
    if coalesce(array_length(why, 1), 0) = 0 then
      if p_dry then
        sent := sent || jsonb_build_object('space', v_name, 'what', 'price list');
        continue;
      end if;
      -- sent as the owner would send it (owner_propose_products reads
      -- who is asking); all of it or none of it. Once sent, the kept
      -- list is forgotten (a null list keeps nothing).
      begin
        perform set_config('request.jwt.claims',
          jsonb_build_object('role', 'authenticated', 'email', p.owner_email)::text, true);
        res := public.owner_propose_products(p.venue_id, p.price_rows, p.currency);
        if jsonb_array_length(coalesce(res -> 'problems', '[]'::jsonb)) > 0 then
          raise exception '%', (
            select string_agg('"' || coalesce(x ->> 'name', '') || '": ' || coalesce(x ->> 'why', ''), '; ')
              from jsonb_array_elements(res -> 'problems') x);
        end if;
        perform public.owner_save_price_draft(p.venue_id, null, null);
      exception when others then
        why := array[left(sqlerrm, 300)];
        res := null;
      end;
      perform set_config('request.jwt.claims', '', true);
    end if;
    if res is null then
      held_ := held_ || jsonb_build_object('space', v_name, 'what', 'price list', 'why', to_jsonb(why));
      if not p_dry then
        update public.owner_price_drafts set held = why, checked_at = now()
         where venue_id = p.venue_id;
      end if;
      continue;
    end if;
    n := coalesce((res ->> 'added')::integer, 0) + coalesce((res ->> 'changed')::integer, 0)
       + coalesce((res ->> 'removed')::integer, 0);
    if n > 0 then
      sent := sent || jsonb_build_object('space', v_name, 'what', 'price list', 'changes', n);
      perform public.notify_phone(
        'Owner price list to check',
        coalesce(v_name, 'A space') || ': ' || n
          || case when n = 1 then ' price change' else ' price changes' end
          || '. Sent automatically: the owner left without pressing Save change. '
          || 'Check in Price check.',
        'moneybag');
    end if;
  end loop;

  -- 4. one email, a day after something was held and is still there
  for r in
    select h.venue_id, lower(h.owner_email) as em, array_agg(distinct w) as why
      from (select x.venue_id, x.owner_email, x.held
              from public.owner_drafts x
             where x.status = 'draft' and x.discarded_at is null
               and coalesce(array_length(x.held, 1), 0) > 0
               and x.reminded_at is null
               and x.checked_at < now() - interval '24 hours'
               and x.checked_at >= x.updated_at
            union all
            select x.venue_id, x.owner_email, x.held
              from public.owner_price_drafts x
             where coalesce(array_length(x.held, 1), 0) > 0
               and x.reminded_at is null
               and x.checked_at < now() - interval '24 hours'
               and x.checked_at >= x.updated_at) h,
           unnest(h.held) w
     group by 1, 2
  loop
    select name into v_name from public.venues
     where id = r.venue_id and lower(coalesce(listing_owner_email, '')) = r.em;
    if not found then
      -- no longer theirs: nobody to remind
      if not p_dry then
        update public.owner_drafts set reminded_at = now()
         where venue_id = r.venue_id and status = 'draft' and reminded_at is null;
        update public.owner_price_drafts set reminded_at = now()
         where venue_id = r.venue_id and reminded_at is null;
      end if;
      continue;
    end if;
    mailed := mailed || jsonb_build_object('space', v_name, 'why', to_jsonb(r.why));
    if p_dry then continue; end if;
    first := public.owner_first_name(r.venue_id, r.em);
    acct := 'https://nomadmaps.io/owner?email='
            || replace(replace(r.em, '+', '%2B'), '@', '%40');
    body := 'Hi ' || first || ',' || E'\n\n'
      || 'You started changing your listing for ' || v_name || ' on Nomadwise. '
      || 'Your changes are saved, but we have not sent them for review yet, '
      || 'because something looks unfinished:' || E'\n\n'
      || (select string_agg(upper(left(w, 1)) || substr(w, 2) || '.', E'\n' order by w)
            from unnest(r.why) w)
      || E'\n\n'
      || 'Your page stays as it is for now. In your [Owner account](' || acct || ') '
      || 'you can finish them, send them as they are, or discard them.'
      || E'\n\n'
      || 'To sign in, open the link above and press "Email me a sign-in link": '
      || 'we send a link to ' || r.em || ', no password needed.'
      || case when r.em like '%@gmail.com' or r.em like '%@googlemail.com'
              then ' As it is a Gmail address, "Continue with Google" works too.' else '' end
      || E'\n\n' || 'Any questions, just reply to this email.'
      || E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
    perform public.send_owner_email(
      r.em, 'Your changes to ' || v_name || ' are saved but not sent',
      body, 'changes_unsent', r.venue_id::text, 'Finish my changes', acct);
    update public.owner_drafts set reminded_at = now()
     where venue_id = r.venue_id and status = 'draft' and reminded_at is null;
    update public.owner_price_drafts set reminded_at = now()
     where venue_id = r.venue_id and reminded_at is null;
  end loop;

  return jsonb_build_object('sent', sent, 'held', held_, 'taken_back', back,
                            'reminded', mailed, 'dry', p_dry);
end $function$;
revoke all on function public.owner_autosend_run(boolean) from public, anon, authenticated;

-- ------------------------------------------------ the existing functions
-- A save starts the check again; Save change is the owner's own send.
select public.pm_patch_fn('public.owner_save_draft(uuid,jsonb,boolean)',
  $a$submitted_at = case when p_submit then now() else submitted_at end,$a$,
  $a$submitted_at = case when p_submit then now() else submitted_at end,
           -- (a save starts the "looks unfinished" check again; Save
           -- change is the owner's own send: migration 335)
           held = null,
           auto_sent = case when p_submit then false else auto_sent end,$a$,
  $a$auto_sent$a$);

-- The Owner account is told what is unsent, why it is held, and the
-- price list as it was left.
select public.pm_patch_fn('public.owner_venues()',
  $a$'review_note', d.review_note, 'updated_at', d.updated_at)$a$,
  $a$'review_note', d.review_note, 'updated_at', d.updated_at,
                  'held', to_jsonb(d.held), 'auto_sent', d.auto_sent,
                  'unsent', case when d.status = 'draft'
                                 then public.owner_draft_changes_own(d.venue_id, d.draft) end)$a$,
  $a$owner_draft_changes_own$a$);

select public.pm_patch_fn('public.owner_venues()',
  $a$      'owner_content_at', v.owner_content_at,$a$,
  $a$      'owner_content_at', v.owner_content_at,
      'price_draft', (select jsonb_build_object(
                         'rows', pd.price_rows, 'currency', pd.currency,
                         'held', to_jsonb(pd.held), 'updated_at', pd.updated_at)
                        from public.owner_price_drafts pd
                       where pd.venue_id = v.id),$a$,
  $a$owner_price_drafts$a$);

-- The review card says when it was not the owner who pressed send.
select public.pm_patch_fn('public.owner_drafts_to_review()',
  $a$      'updated_at', d.updated_at,$a$,
  $a$      'updated_at', d.updated_at,
      'auto_sent', d.auto_sent,$a$,
  $a$'auto_sent'$a$);

-- Prices sent: what was kept as typed is no longer unsent (a null
-- list keeps nothing).
select public.pm_patch_fn('public.owner_propose_products(uuid,jsonb,text)',
  $a$  return jsonb_build_object('added', n_add, 'changed', n_up, 'removed', n_rm,$a$,
  $a$  if jsonb_array_length(problems) = 0 then
    perform public.owner_save_price_draft(v.id, null, null);
  end if;

  return jsonb_build_object('added', n_add, 'changed', n_up, 'removed', n_rm,$a$,
  $a$owner_save_price_draft$a$);

-- A draft set aside is nobody's draft: the next save starts a new one,
-- and the Owner account and our own views do not show it.
select public.pm_patch_fn('public.owner_save_draft(uuid,jsonb,boolean)',
  $a$where venue_id = p_venue and status in ('draft', 'submitted')$a$,
  $a$where venue_id = p_venue and status in ('draft', 'submitted')
     and discarded_at is null$a$,
  $a$discarded_at$a$);

select public.pm_patch_fn('public.owner_venues()',
  $a$where d.venue_id = v.id$a$,
  $a$where d.venue_id = v.id and d.discarded_at is null$a$,
  $a$discarded_at$a$);

select public.pm_patch_fn('public.admin_owner_view(text)',
  $a$where d.venue_id = v.id$a$,
  $a$where d.venue_id = v.id and d.discarded_at is null$a$,
  $a$discarded_at$a$);

select public.pm_patch_fn('public.admin_space_profile(uuid)',
  $a$from public.owner_drafts d where d.venue_id = p_venue$a$,
  $a$from public.owner_drafts d where d.venue_id = p_venue and d.discarded_at is null$a$,
  $a$discarded_at$a$);

-- every five minutes
select cron.unschedule(jobid) from cron.job where jobname = 'owner-autosend';
select cron.schedule('owner-autosend', '*/5 * * * *', $$select public.owner_autosend_run()$$);
