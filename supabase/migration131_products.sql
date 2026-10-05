-- Migration 131: products and the price check.
--
-- A coworking space sells things: a day pass, a month pass, a meeting
-- room by the hour, a private office. On nomadwise.io these live in
-- the Webflow "Products" collection (753 of them on 153 pages, almost
-- all last touched in May or August 2025). Nomad Maps had no copy and
-- no way to tell whether a price was still true.
--
-- The rule this serves (Jonathan, 5 Oct 2026): the bare minimum
-- expected of us is that a price on a listing is the price on the
-- space's own website. If a space ever asks, the answer has to be "it
-- is the one on your site".
--
-- What this adds:
--
--   venue_products    our copy of each product, with the day it was
--                     last compared with the space's own website. The
--                     website push keeps it in step with Webflow.
--   price_checks      a founder asks for one space's prices to be
--                     checked; the check itself is done in a session
--                     that opens the space's website and loads what
--                     it found with import_price_check().
--   product_changes   what the check proposes, one row per product:
--                     a new price or name, a product to add, one that
--                     is no longer offered. Nothing reaches the public
--                     page until a founder presses Go on that row. The
--                     ten-minute website push then writes it to
--                     Webflow, and Undo puts the old one back.
--
-- A product found unchanged is stamped as checked straight away: that
-- changes nothing on the page.
--
-- Old prices stay on the pages exactly as they are until they are
-- reviewed, one space at a time.

-- ------------------------------------------------------------ tables

create table if not exists public.venue_products (
  id              uuid primary key default gen_random_uuid(),
  venue_id        uuid not null references public.venues(id) on delete cascade,
  webflow_item_id text unique,
  webflow_slug    text,
  name            text not null,
  category        text not null default 'coworking'
                  check (category in ('coworking','meeting_room','private_office','other')),
  amount          numeric,
  currency        text,
  price_label     text not null default '',
  starting_from   boolean not null default false,
  vat_included    boolean,
  details         jsonb not null default '[]'::jsonb,
  position        integer not null default 0,
  status          text not null default 'live' check (status in ('live','removed')),
  source          text not null default 'website'
                  check (source in ('website','check','founder','owner')),
  extra           jsonb not null default '{}'::jsonb,
  site_updated_at timestamptz,
  -- The last time this product was compared with the space's own
  -- website and found to be right (the same, or corrected to match).
  checked_at      timestamptz,
  checked_url     text,
  -- The last look, whatever it found.
  -- same: matches their website. changed: corrected to match it.
  -- differs: their website shows something else and the page has
  -- not been changed. not_found: not on their website.
  check_result    text check (check_result in ('same','changed','differs','not_found')),
  check_note      text,
  check_seen_at   timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists idx_venue_products_venue on public.venue_products(venue_id);
alter table public.venue_products enable row level security;

create table if not exists public.price_checks (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues(id) on delete cascade,
  status       text not null default 'requested'
               check (status in ('requested','done','cancelled')),
  note         text check (note is null or length(note) <= 2000),
  requested_by text,
  requested_at timestamptz not null default now(),
  done_at      timestamptz,
  checked_url  text,
  checked_on   date,
  summary      text,
  result       jsonb
);
create index if not exists idx_price_checks_venue on public.price_checks(venue_id);
create unique index if not exists idx_price_checks_one_requested
  on public.price_checks(venue_id) where status = 'requested';
alter table public.price_checks enable row level security;

create table if not exists public.product_changes (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.venues(id) on delete cascade,
  product_id  uuid references public.venue_products(id) on delete cascade,
  action      text not null check (action in ('update','add','remove')),
  before      jsonb,
  proposed    jsonb,
  final       jsonb,
  note        text check (note is null or length(note) <= 2000),
  source_url  text,
  checked_on  date,
  source      text not null default 'check' check (source in ('check','founder','owner')),
  status      text not null default 'proposed'
              check (status in ('proposed','approved','applied','skipped',
                                'failed','undo_requested','undone')),
  error       text,
  batch       text,
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  decided_by  text,
  applied_at  timestamptz,
  -- Set by the website push the moment it starts writing this change,
  -- so a founder cannot take it back half way through.
  claimed_at  timestamptz
);
create index if not exists idx_product_changes_venue on public.product_changes(venue_id);
create index if not exists idx_product_changes_status on public.product_changes(status);
-- One change in hand per product: waiting, on its way, or failed.
create unique index if not exists idx_product_changes_one_open
  on public.product_changes(product_id)
  where product_id is not null
    and status in ('proposed','approved','failed','undo_requested');
alter table public.product_changes enable row level security;

-- ----------------------------------------------------------- helpers

-- How a price is written: euro, pound and dollar with the symbol in
-- front, every other currency with its code after the amount. Whole
-- amounts carry no decimals.
create or replace function public.product_label(p_amount numeric, p_currency text)
returns text language sql immutable as $$
  select case
    when p_amount is null then 'Price on request'
    else (
      select case upper(coalesce(p_currency, ''))
               when 'EUR' then '€' || n
               when 'GBP' then '£' || n
               when 'USD' then '$' || n
               when 'AUD' then 'A$' || n
               when '' then n
               else n || ' ' || upper(p_currency)
             end
        from (select case when p_amount = trunc(p_amount)
                          then to_char(p_amount, 'FM999,999,999,999,990')
                          else to_char(p_amount, 'FM999,999,999,999,990.00')
                     end as n) x)
  end
$$;

-- One line of text, tidied: single spaces, and plain hyphens where a
-- long dash was typed or copied (house style).
create or replace function public.product_tidy(p text)
returns text language sql immutable as $$
  select btrim(regexp_replace(
           replace(replace(coalesce(p, ''), '—', ' - '), '–', '-'),
           '\s+', ' ', 'g'))
$$;

-- A product as the app and the website push pass it around.
create or replace function public.product_json(p public.venue_products)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'name', p.name,
    'category', p.category,
    'amount', p.amount,
    'currency', p.currency,
    'label', p.price_label,
    'starting_from', p.starting_from,
    'vat_included', p.vat_included,
    'details', p.details)
$$;

-- Tidy a product someone typed or a check found, on top of what is
-- there now (p_base), so a proposal may name only what changes. The
-- label follows the amount unless one is given: "£40 + VAT" has to be
-- written out, "€25" writes itself.
create or replace function public.product_clean(p jsonb, p_base jsonb default null)
returns jsonb language plpgsql immutable as $$
declare
  b        jsonb := coalesce(p_base, '{}'::jsonb);
  name_    text;
  cat      text;
  amt      numeric;
  cur      text;
  lab      text;
  from_    boolean;
  vat      boolean;
  det      jsonb;
  given    text;
  moved    boolean;
begin
  p := coalesce(p, '{}'::jsonb);
  name_ := public.product_tidy(coalesce(p->>'name', b->>'name', ''));
  cat := lower(btrim(coalesce(p->>'category', b->>'category', 'coworking')));
  cat := case cat
           when 'meeting-room' then 'meeting_room'
           when 'meeting room' then 'meeting_room'
           when 'private-office' then 'private_office'
           when 'private office' then 'private_office'
           when 'other-options' then 'other'
           when 'other options' then 'other'
           else cat end;
  if p ? 'amount' then
    -- A number, or text that reads one way only: "1500", "12.50",
    -- "1,500" (commas group thousands). "12,50" is refused rather
    -- than guessed at.
    if jsonb_typeof(p->'amount') = 'number' then
      amt := (p->>'amount')::numeric;
    elsif coalesce(btrim(p->>'amount'), '') = '' then
      amt := null;
    elsif btrim(p->>'amount') ~ '^\d+(\.\d+)?$'
       or btrim(p->>'amount') ~ '^\d{1,3}(,\d{3})+(\.\d+)?$' then
      amt := replace(btrim(p->>'amount'), ',', '')::numeric;
    else
      raise exception 'unreadable amount';
    end if;
  else
    amt := case when jsonb_typeof(b->'amount') = 'number' then (b->>'amount')::numeric
                else null end;
  end if;
  amt := trim_scale(round(amt, 2));   -- the website keeps two decimals
  cur := nullif(upper(btrim(coalesce(p->>'currency', b->>'currency', ''))), '');
  -- A key that is missing, or null, leaves what is there.
  from_ := coalesce(case when jsonb_typeof(p->'starting_from') = 'boolean'
                         then (p->>'starting_from')::boolean
                         else (b->>'starting_from')::boolean end, false);
  vat := case when jsonb_typeof(p->'vat_included') = 'boolean'
              then (p->>'vat_included')::boolean
              else (b->>'vat_included')::boolean end;
  -- Details: one short line each, empty lines dropped.
  det := case when jsonb_typeof(p->'details') = 'array' then p->'details'
              when jsonb_typeof(b->'details') = 'array' then b->'details'
              else '[]'::jsonb end;
  select coalesce(jsonb_agg(t order by ord), '[]'::jsonb) into det
    from (select public.product_tidy(value) as t, ord
            from jsonb_array_elements_text(det) with ordinality as e(value, ord)) x
   where t <> '';
  -- The label: the one given; else the old one while the price has
  -- not moved; else written from the amount.
  given := public.product_tidy(coalesce(p->>'label', ''));
  moved := (amt is distinct from
              (case when jsonb_typeof(b->'amount') = 'number'
                    then (b->>'amount')::numeric else null end))
           or (cur is distinct from nullif(upper(btrim(coalesce(b->>'currency', ''))), ''));
  lab := case when given <> '' then given
              when not moved and b ? 'label' then btrim(coalesce(b->>'label', ''))
              else public.product_label(amt, cur) end;
  return jsonb_build_object(
    'name', name_, 'category', cat, 'amount', amt, 'currency', cur,
    'label', lab, 'starting_from', from_, 'vat_included', vat, 'details', det);
exception when others then
  -- An amount that is not a number, a tick that is not yes or no.
  return jsonb_build_object('problem',
    'One of the values could not be read (the price must be a number).');
end $$;

-- What is wrong with a tidied product, or null when it can go on a page.
create or replace function public.product_problem(p jsonb)
returns text language plpgsql immutable as $$
declare
  n   text := coalesce(p->>'name', '');
  amt numeric;
  d   text;
begin
  if p ? 'problem' then
    return p->>'problem';
  end if;
  if length(n) < 2 then
    return 'The product needs a name.';
  end if;
  if length(n) > 80 then
    return 'The name is too long (80 characters at most).';
  end if;
  if coalesce(p->>'category', '') not in ('coworking','meeting_room','private_office','other') then
    return 'The category must be Coworking, Meeting room, Private office or Other.';
  end if;
  if jsonb_typeof(p->'amount') = 'number' then
    amt := (p->>'amount')::numeric;
    if amt < 0 or amt >= 1000000000000 then
      return 'The price is out of range.';
    end if;
    if coalesce(p->>'currency', '') !~ '^[A-Z]{3}$' then
      return 'A price needs its currency (three letters, like EUR or IDR).';
    end if;
  end if;
  if length(coalesce(p->>'label', '')) > 40 then
    return 'The price as shown is too long (40 characters at most).';
  end if;
  if jsonb_array_length(coalesce(p->'details', '[]'::jsonb)) > 20 then
    return 'Too many detail lines (20 at most).';
  end if;
  for d in select value from jsonb_array_elements_text(coalesce(p->'details', '[]'::jsonb)) loop
    if length(d) > 400 then
      return 'A detail line is too long (400 characters at most).';
    end if;
  end loop;
  return null;
end $$;

-- The site address of a space's page, for the lists.
create or replace function public.product_page_url(v public.venues)
returns text language sql stable as $$
  select case when coalesce(v.webflow_slug, '') <> ''
              then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end
$$;

-- --------------------------------------------- copy from the website

-- Our copy of the Webflow Products collection. Called with the first
-- load (migration 132) and then by the website push about once a day,
-- so a product edited by hand in Webflow is seen here too. Rows are
-- matched on the Webflow item; the days a product was checked are
-- kept. With p_full, a product that is no longer in the collection is
-- marked removed.
create or replace function public.set_venue_products(p jsonb, p_full boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r         jsonb;
  v_id      uuid;
  c         jsonb;
  live_     boolean;
  n_in      integer := 0;
  n_up      integer := 0;
  n_gone    integer := 0;
  unmatched jsonb := '[]'::jsonb;
  seen      text[] := '{}';
  had       integer;
  who       text;
  lab       text;
begin
  for r in select value from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    if coalesce(r->>'item', '') = '' then
      continue;
    end if;
    seen := seen || (r->>'item');
    live_ := coalesce((r->>'live')::boolean, true);
    select v.id into v_id from public.venues v
     where (coalesce(r->>'venue_cms', '') <> '' and v.webflow_cms_id = r->>'venue_cms')
        or (coalesce(r->>'venue_slug', '') <> '' and v.webflow_slug = r->>'venue_slug')
     order by (v.webflow_cms_id = r->>'venue_cms') desc nulls last
     limit 1;
    if v_id is null then
      -- A product whose space we do not hold (or one never linked to
      -- a space). Left out; named in the result.
      if exists (select 1 from public.venue_products x where x.webflow_item_id = r->>'item') then
        update public.venue_products set status = 'removed', updated_at = now()
         where webflow_item_id = r->>'item' and status <> 'removed' and not live_;
      else
        who := coalesce(nullif(r->>'venue_slug', ''), nullif(r->>'venue_cms', ''),
                        r->>'name', '?');
        if jsonb_array_length(unmatched) < 40 and not unmatched ? who then
          unmatched := unmatched || jsonb_build_array(who);
        end if;
      end if;
      continue;
    end if;
    c := public.product_clean(r, null);
    if c ? 'problem' or length(coalesce(c->>'name', '')) < 1 then
      continue;
    end if;
    -- The label is kept as the website has it, empty when it is empty:
    -- our copy must not show a price the page does not.
    lab := public.product_tidy(coalesce(r->>'label', ''));
    if exists (select 1 from public.venue_products x where x.webflow_item_id = r->>'item') then
      update public.venue_products x set
        venue_id        = v_id,
        webflow_slug    = coalesce(r->>'slug', x.webflow_slug),
        name            = c->>'name',
        category        = case when (c->>'category') in
                                 ('coworking','meeting_room','private_office','other')
                               then c->>'category' else x.category end,
        amount          = (c->>'amount')::numeric,
        currency        = c->>'currency',
        price_label     = lab,
        starting_from   = (c->>'starting_from')::boolean,
        vat_included    = (c->>'vat_included')::boolean,
        details         = c->'details',
        position        = coalesce((r->>'position')::integer, x.position),
        status          = case when live_ then 'live' else 'removed' end,
        extra           = coalesce(r->'extra', x.extra),
        site_updated_at = coalesce((r->>'site_updated_at')::timestamptz, x.site_updated_at),
        -- A name or price changed by hand in Webflow since the last
        -- check is no longer a checked one.
        checked_at      = case when x.name is distinct from c->>'name'
                                 or x.amount is distinct from (c->>'amount')::numeric
                                 or x.price_label is distinct from lab
                               then null else x.checked_at end,
        checked_url     = case when x.name is distinct from c->>'name'
                                 or x.amount is distinct from (c->>'amount')::numeric
                                 or x.price_label is distinct from lab
                               then null else x.checked_url end,
        check_result    = case when x.name is distinct from c->>'name'
                                 or x.amount is distinct from (c->>'amount')::numeric
                                 or x.price_label is distinct from lab
                               then null else x.check_result end,
        check_note      = case when x.name is distinct from c->>'name'
                                 or x.amount is distinct from (c->>'amount')::numeric
                                 or x.price_label is distinct from lab
                               then null else x.check_note end,
        updated_at      = now()
      where x.webflow_item_id = r->>'item';
      n_up := n_up + 1;
    elsif live_ then
      insert into public.venue_products
        (venue_id, webflow_item_id, webflow_slug, name, category, amount, currency,
         price_label, starting_from, vat_included, details, position, status, source,
         extra, site_updated_at)
      values
        (v_id, r->>'item', r->>'slug', c->>'name',
         case when (c->>'category') in ('coworking','meeting_room','private_office','other')
              then c->>'category' else 'coworking' end,
         (c->>'amount')::numeric, c->>'currency', lab,
         (c->>'starting_from')::boolean, (c->>'vat_included')::boolean, c->'details',
         coalesce((r->>'position')::integer, 0), 'live', 'website',
         coalesce(r->'extra', '{}'::jsonb), (r->>'site_updated_at')::timestamptz);
      n_in := n_in + 1;
    end if;
  end loop;
  if p_full then
    -- Only on a read that looks whole: a short answer from Webflow
    -- must not wipe the list.
    select count(*) into had from public.venue_products
     where webflow_item_id is not null and status = 'live';
    if coalesce(array_length(seen, 1), 0) >= greatest(1, had / 2) then
      update public.venue_products set status = 'removed', updated_at = now()
       where webflow_item_id is not null and status = 'live'
         and not (webflow_item_id = any(seen));
      get diagnostics n_gone = row_count;
    end if;
  end if;
  -- A proposal for a product that is no longer on the page has
  -- nothing left to change.
  update public.product_changes c
     set status = 'skipped', decided_at = now(),
         error = 'The product was taken off the page in Webflow.'
    from public.venue_products x
   where x.id = c.product_id and x.status = 'removed'
     and c.action in ('update', 'remove') and c.status in ('proposed', 'failed');
  return jsonb_build_object('added', n_in, 'updated', n_up, 'removed', n_gone,
                            'unmatched', unmatched);
end $$;
revoke all on function public.set_venue_products(jsonb, boolean) from public, anon, authenticated;
grant execute on function public.set_venue_products(jsonb, boolean) to service_role;

-- Whether the daily copy from Webflow is due (the push runs every ten
-- minutes; the copy is wanted about once a day).
create or replace function public.products_pull_due()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select s.updated_at < now() - interval '20 hours'
                     from public.sync_settings s where s.key = 'products_pull'), true)
$$;
revoke all on function public.products_pull_due() from public, anon, authenticated;
grant execute on function public.products_pull_due() to service_role;

-- ------------------------------------------------- loading a check

-- Which product of a space a check means: its id here, its Webflow
-- item, the first characters of its id, or its exact name when only
-- one live product of the space carries it.
create or replace function public.product_find(p_venue uuid, p_ref text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
  ref_ text := btrim(coalesce(p_ref, ''));
  out  uuid;
  n    integer;
begin
  if ref_ = '' then
    return null;
  end if;
  if ref_ ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select id into out from public.venue_products
     where venue_id = p_venue and id = ref_::uuid;
    return out;
  end if;
  select id into out from public.venue_products
   where venue_id = p_venue and webflow_item_id = ref_;
  if out is not null then
    return out;
  end if;
  if ref_ ~* '^[0-9a-f]{8,}$' then
    select count(*), (array_agg(id))[1] into n, out from public.venue_products
     where venue_id = p_venue and id::text like lower(ref_) || '%';
    if n = 1 then
      return out;
    end if;
  end if;
  select count(*), (array_agg(id))[1] into n, out from public.venue_products
   where venue_id = p_venue and status = 'live' and lower(name) = lower(ref_);
  if n = 1 then
    return out;
  end if;
  return null;
end $$;
revoke all on function public.product_find(uuid, text) from public, anon, authenticated;

-- What a check found, loaded in one go. One entry per space:
--
--   {"slug": "germany-hamburg-4-walls-coworking",
--    "url": "https://their-site.example/prices", "checked_on": "2026-10-05",
--    "summary": "one or two sentences on what their prices page shows",
--    "items": [
--      {"ref": "Day Pass", "result": "same"},
--      {"ref": "Week Pass", "result": "changed", "amount": 95,
--       "note": "Shown as 95 € per week"},
--      {"ref": "Night Pass", "result": "not_found",
--       "note": "Not on their prices page; their site does not say it ended"},
--      {"ref": "Old Pass", "result": "gone", "note": "Their site says ..."},
--      {"result": "new", "name": "Evening Pass", "category": "coworking",
--       "amount": 12, "currency": "EUR", "note": "..."}]}
--
-- same       stamped as checked; nothing to press.
-- changed    a proposal the founder sees next to the current one.
-- not_found  noted on the product; nothing proposed.
-- gone       a proposal to take the product off the page.
-- new        a proposal to add a product.
--
-- Returns what was loaded and what was left out, and why.
create or replace function public.import_price_check(p jsonb, p_batch text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e        jsonb;
  it       jsonb;
  v        public.venues%rowtype;
  pr       public.venue_products%rowtype;
  open_    public.product_changes%rowtype;
  pid      uuid;
  base     jsonb;
  fin      jsonb;
  why      text;
  res      text;
  url_     text;
  on_      date;
  note_    text;
  n        jsonb;
  skipped  jsonb := '[]'::jsonb;
  spaces   integer := 0;
  total    jsonb := jsonb_build_object('same', 0, 'changed', 0, 'not_found', 0,
                                        'gone', 0, 'new', 0);
begin
  for e in select value from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    select * into v from public.venues x
     where x.webflow_slug = e->>'slug' limit 1;
    if not found then
      skipped := skipped || jsonb_build_array(jsonb_build_object(
        'slug', e->>'slug', 'why', 'no space with this page address'));
      continue;
    end if;
    url_ := nullif(btrim(coalesce(e->>'url', '')), '');
    on_ := coalesce((e->>'checked_on')::date, current_date);
    n := jsonb_build_object('same', 0, 'changed', 0, 'not_found', 0, 'gone', 0, 'new', 0);
    spaces := spaces + 1;
    for it in select value from jsonb_array_elements(coalesce(e->'items', '[]'::jsonb)) loop
      res := lower(coalesce(it->>'result', ''));
      note_ := nullif(left(btrim(coalesce(it->>'note', '')), 2000), '');
      if res not in ('same','changed','not_found','gone','new') then
        skipped := skipped || jsonb_build_array(jsonb_build_object(
          'slug', v.webflow_slug, 'ref', coalesce(it->>'ref', it->>'name'),
          'why', 'unknown result'));
        continue;
      end if;

      if res = 'new' then
        fin := public.product_clean(it, jsonb_build_object(
                 'currency', (select x.currency from public.venue_products x
                               where x.venue_id = v.id and x.status = 'live'
                                 and x.currency is not null
                               group by x.currency order by count(*) desc limit 1)));
        if not (fin ? 'problem') then
          fin := fin || jsonb_build_object('starting_from', false);
        end if;
        why := public.product_problem(fin);
        if why is null and exists (select 1 from public.venue_products x
               where x.venue_id = v.id and x.status = 'live'
                 and lower(x.name) = lower(fin->>'name')) then
          why := 'a product with this name is already on the page';
        end if;
        if why is null and exists (select 1 from public.product_changes x
               where x.venue_id = v.id and x.action = 'add'
                 and x.status in ('approved','undo_requested')
                 and lower(coalesce(x.final, x.proposed)->>'name') = lower(fin->>'name')) then
          why := 'this product is already on its way to the page';
        end if;
        if why is not null then
          skipped := skipped || jsonb_build_array(jsonb_build_object(
            'slug', v.webflow_slug, 'ref', it->>'name', 'why', why));
          continue;
        end if;
        -- A waiting or failed proposal for the same new product is
        -- replaced by this one.
        delete from public.product_changes x
         where x.venue_id = v.id and x.action = 'add'
           and x.status in ('proposed','failed') and x.source = 'check'
           and lower(coalesce(x.final, x.proposed)->>'name') = lower(fin->>'name');
        insert into public.product_changes
          (venue_id, action, proposed, final, note, source_url, checked_on, source, batch)
        values (v.id, 'add', fin, fin, note_, url_, on_, 'check', p_batch);
        n := jsonb_set(n, '{new}', to_jsonb((n->>'new')::integer + 1));
        continue;
      end if;

      pid := public.product_find(v.id, it->>'ref');
      if pid is null then
        skipped := skipped || jsonb_build_array(jsonb_build_object(
          'slug', v.webflow_slug, 'ref', it->>'ref',
          'why', 'no product, or more than one, matches this name'));
        continue;
      end if;
      select * into pr from public.venue_products where id = pid;
      if pr.status <> 'live' then
        skipped := skipped || jsonb_build_array(jsonb_build_object(
          'slug', v.webflow_slug, 'ref', it->>'ref', 'why', 'this product is no longer on the page'));
        continue;
      end if;
      base := public.product_json(pr);

      if res = 'changed' then
        fin := public.product_clean(it, base);
        why := public.product_problem(fin);
        if why is not null then
          skipped := skipped || jsonb_build_array(jsonb_build_object(
            'slug', v.webflow_slug, 'ref', it->>'ref', 'why', why));
          continue;
        end if;
        if fin = public.product_clean('{}'::jsonb, base) then
          res := 'same';   -- nothing differs after tidying
        end if;
      end if;

      select * into open_ from public.product_changes x
       where x.product_id = pid
         and x.status in ('proposed','approved','failed','undo_requested')
       limit 1;
      if found and open_.status in ('approved','undo_requested') then
        skipped := skipped || jsonb_build_array(jsonb_build_object(
          'slug', v.webflow_slug, 'ref', it->>'ref',
          'why', 'a change to this product is on its way to the page'));
        continue;
      end if;

      if res in ('same', 'not_found') then
        -- A fresh look replaces a proposal still waiting from an
        -- earlier one: that proposal was built on an older reading.
        if found and open_.source = 'check' then
          delete from public.product_changes where id = open_.id;
        end if;
        update public.venue_products set
          checked_at    = case when res = 'same' then on_::timestamptz else checked_at end,
          checked_url   = case when res = 'same' then url_ else checked_url end,
          check_result  = res,
          check_note    = note_,
          check_seen_at = now(),
          updated_at    = now()
        where id = pid;
        n := jsonb_set(n, array[res], to_jsonb((n->>res)::integer + 1));
        continue;
      end if;

      -- changed or gone: a proposal for the founder.
      if found then
        delete from public.product_changes where id = open_.id;
      end if;
      insert into public.product_changes
        (venue_id, product_id, action, before, proposed, final, note, source_url,
         checked_on, source, batch)
      values (v.id, pid, case when res = 'gone' then 'remove' else 'update' end,
              base,
              case when res = 'gone' then null else fin end,
              case when res = 'gone' then null else fin end,
              note_, url_, on_, 'check', p_batch);
      -- Their website shows something else: the product is not a
      -- checked one until the change is on the page.
      update public.venue_products set
        checked_at = null, checked_url = null, check_result = 'differs',
        check_note = note_, check_seen_at = now(), updated_at = now()
       where id = pid;
      n := jsonb_set(n, array[res], to_jsonb((n->>res)::integer + 1));
    end loop;

    -- The request, if there was one, is answered; either way the look
    -- is on record.
    update public.price_checks set
      status = 'done', done_at = now(), checked_url = url_, checked_on = on_,
      summary = nullif(left(btrim(coalesce(e->>'summary', '')), 2000), ''),
      result = n
    where venue_id = v.id and status = 'requested';
    if not found then
      insert into public.price_checks
        (venue_id, status, requested_by, done_at, checked_url, checked_on, summary, result)
      values (v.id, 'done', null, now(), url_, on_,
              nullif(left(btrim(coalesce(e->>'summary', '')), 2000), ''), n);
    end if;
    total := jsonb_build_object(
      'same', (total->>'same')::integer + (n->>'same')::integer,
      'changed', (total->>'changed')::integer + (n->>'changed')::integer,
      'not_found', (total->>'not_found')::integer + (n->>'not_found')::integer,
      'gone', (total->>'gone')::integer + (n->>'gone')::integer,
      'new', (total->>'new')::integer + (n->>'new')::integer);
  end loop;
  return jsonb_build_object('spaces', spaces, 'found', total, 'skipped', skipped);
end $$;
revoke all on function public.import_price_check(jsonb, text) from public, anon, authenticated;
grant execute on function public.import_price_check(jsonb, text) to service_role;

-- ---------------------------------------------------- control centre

-- One change, as a card shows it.
create or replace function public.product_change_json(c public.product_changes)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', c.id, 'action', c.action, 'status', c.status, 'source', c.source,
    'before', c.before, 'proposed', c.proposed, 'final', c.final,
    'note', c.note, 'source_url', c.source_url, 'checked_on', c.checked_on,
    'error', c.error, 'created_at', c.created_at, 'decided_at', c.decided_at,
    'applied_at', c.applied_at, 'product_id', c.product_id)
$$;

-- The numbers at the top of the Price check screen.
create or replace function public.admin_prices_overview()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  return jsonb_build_object(
    'spaces', (select count(distinct venue_id) from public.venue_products where status = 'live'),
    'products', (select count(*) from public.venue_products where status = 'live'),
    'checked', (select count(*) from public.venue_products
                 where status = 'live' and checked_at is not null),
    'spaces_checked', (select count(*) from (
                         select venue_id from public.venue_products where status = 'live'
                          group by venue_id having bool_and(check_seen_at is not null)) x),
    'oldest', (select min(site_updated_at) from public.venue_products
                where status = 'live' and checked_at is null),
    'requested', (select count(*) from public.price_checks where status = 'requested'),
    'waiting', (select count(*) from public.product_changes where status = 'proposed'),
    'on_the_way', (select count(*) from public.product_changes
                    where status in ('approved','undo_requested')),
    'failed', (select count(*) from public.product_changes where status = 'failed'),
    'pulled_at', (select updated_at from public.sync_settings where key = 'products_pull'),
    'pull_note', (select value from public.sync_settings where key = 'products_pull'));
end $$;
revoke all on function public.admin_prices_overview() from public, anon;
grant execute on function public.admin_prices_overview() to authenticated;

-- The spaces that have products, to pick one. Filters: '' (all),
-- 'requested', 'waiting' (something to decide), 'unchecked' (never
-- looked at), 'checked'.
create or replace function public.admin_prices_spaces(
  p_q text default '', p_filter text default '', p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q   text := lower(btrim(coalesce(p_q, '')));
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  with s as (
    select v.id, v.name, v.city, v.country, v.webflow_slug, v.website,
           v.listing_owner_email is not null as owned,
           public.upgrade_page_is_live(v) as page_live,
           public.product_page_url(v) as page,
           count(*) filter (where p.status = 'live') as products,
           count(*) filter (where p.status = 'live' and p.checked_at is not null) as checked,
           count(*) filter (where p.status = 'live' and p.check_seen_at is not null) as seen,
           min(p.site_updated_at) filter (where p.status = 'live') as site_oldest,
           max(p.check_seen_at) as last_seen,
           (select count(*) from public.product_changes c
             where c.venue_id = v.id and c.status = 'proposed') as waiting,
           (select count(*) from public.product_changes c
             where c.venue_id = v.id and c.status in ('approved','undo_requested')) as on_the_way,
           (select count(*) from public.product_changes c
             where c.venue_id = v.id and c.status = 'failed') as failed,
           (select jsonb_build_object('note', r.note, 'at', r.requested_at)
              from public.price_checks r
             where r.venue_id = v.id and r.status = 'requested' limit 1) as request
      from public.venues v
      join public.venue_products p on p.venue_id = v.id
     group by v.id
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.ord, x.name), '[]'::jsonb) into out
    from (
      select s.*,
             case when s.waiting + s.failed > 0 then 0
                  when s.request is not null then 1
                  when s.on_the_way > 0 then 2
                  else 3 end as ord
        from s
       where s.products > 0
         and (q = '' or lower(s.name) like '%' || q || '%'
              or lower(coalesce(s.city, '')) like '%' || q || '%'
              or lower(coalesce(s.country, '')) like '%' || q || '%'
              or lower(coalesce(s.webflow_slug, '')) like '%' || q || '%')
         and case coalesce(p_filter, '')
               when 'requested' then s.request is not null
               when 'waiting' then s.waiting + s.failed + s.on_the_way > 0
               when 'unchecked' then s.seen = 0
               when 'checked' then s.seen > 0
               else true end
       order by ord, s.name
       limit greatest(1, least(coalesce(p_limit, 60), 300))
    ) x;
  return out;
end $$;
revoke all on function public.admin_prices_spaces(text, text, integer) from public, anon;
grant execute on function public.admin_prices_spaces(text, text, integer) to authenticated;

-- One space: its products, what is waiting on each, the request and
-- the last check.
create or replace function public.admin_prices_space(p_venue uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v   public.venues%rowtype;
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into v from public.venues where id = p_venue;
  if not found then
    raise exception 'This space could not be found.';
  end if;
  select jsonb_build_object(
    'venue', jsonb_build_object(
      'id', v.id, 'name', v.name, 'city', v.city, 'country', v.country,
      'webflow_slug', v.webflow_slug, 'website', v.website,
      'page', public.product_page_url(v),
      'page_live', public.upgrade_page_is_live(v),
      'owned', v.listing_owner_email is not null,
      'currency', (select x.currency from public.venue_products x
                    where x.venue_id = v.id and x.status = 'live' and x.currency is not null
                    group by x.currency order by count(*) desc limit 1)),
    'request', (select jsonb_build_object('note', r.note, 'at', r.requested_at)
                  from public.price_checks r
                 where r.venue_id = v.id and r.status = 'requested' limit 1),
    'last_check', (select jsonb_build_object(
                     'done_at', r.done_at, 'checked_url', r.checked_url,
                     'checked_on', r.checked_on, 'summary', r.summary, 'result', r.result)
                     from public.price_checks r
                    where r.venue_id = v.id and r.status = 'done'
                    order by r.done_at desc limit 1),
    'products', (select coalesce(jsonb_agg(
        public.product_json(p) || jsonb_build_object(
          'id', p.id, 'position', p.position, 'on_site', p.webflow_item_id is not null,
          'site_updated_at', p.site_updated_at, 'checked_at', p.checked_at,
          'checked_url', p.checked_url, 'check_result', p.check_result,
          'check_note', p.check_note, 'check_seen_at', p.check_seen_at,
          'discount', coalesce((p.extra->>'discount_applied')::boolean, false),
          'affiliate', coalesce((p.extra->>'affiliate')::boolean, false),
          'open', (select public.product_change_json(c) from public.product_changes c
                    where c.product_id = p.id
                      and c.status in ('proposed','approved','failed','undo_requested')
                    limit 1),
          'last', (select public.product_change_json(c) from public.product_changes c
                    where c.product_id = p.id and c.status in ('applied','skipped')
                    order by coalesce(c.applied_at, c.decided_at, c.created_at) desc limit 1))
        order by p.position, p.name), '[]'::jsonb)
        from public.venue_products p
       where p.venue_id = v.id and p.status = 'live'),
    'adds', (select coalesce(jsonb_agg(public.product_change_json(c) order by c.created_at), '[]'::jsonb)
               from public.product_changes c
              where c.venue_id = v.id and c.action = 'add' and c.product_id is null
                and c.status in ('proposed','approved','failed','skipped')
                -- A skipped one stays a month, to bring back; a
                -- founder's own, once taken back, is simply made again.
                and (c.status <> 'skipped'
                     or (c.source = 'check' and c.decided_at > now() - interval '30 days'))),
    'removed', (select coalesce(jsonb_agg(
        public.product_json(p) || jsonb_build_object(
          'id', p.id,
          'open', (select public.product_change_json(c) from public.product_changes c
                    where c.product_id = p.id
                      and c.status in ('proposed','approved','failed','undo_requested')
                    limit 1),
          'last', (select public.product_change_json(c) from public.product_changes c
                    where c.product_id = p.id and c.status = 'applied'
                    order by c.applied_at desc limit 1))
        order by p.updated_at desc), '[]'::jsonb)
        from public.venue_products p
       where p.venue_id = v.id and p.status = 'removed'
         and exists (select 1 from public.product_changes c
                      where c.product_id = p.id
                        and (c.status in ('proposed','approved','undo_requested','failed')
                             or (c.status = 'applied'
                                 and c.applied_at > now() - interval '30 days'))))
  ) into out;
  return out;
end $$;
revoke all on function public.admin_prices_space(uuid) from public, anon;
grant execute on function public.admin_prices_space(uuid) to authenticated;

-- Ask for a space's prices to be checked (or change the note).
create or replace function public.admin_price_check_request(p_venue uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  note_ text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if length(coalesce(note_, '')) > 2000 then
    raise exception 'The note is too long (2,000 characters at most).';
  end if;
  if not exists (select 1 from public.venues where id = p_venue) then
    raise exception 'This space could not be found.';
  end if;
  update public.price_checks set note = note_, requested_at = now(),
         requested_by = public.upgrades_admin_email()
   where venue_id = p_venue and status = 'requested';
  if not found then
    begin
      insert into public.price_checks (venue_id, note, requested_by)
      values (p_venue, note_, public.upgrades_admin_email());
    exception when unique_violation then
      update public.price_checks set note = note_
       where venue_id = p_venue and status = 'requested';
    end;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_price_check_request(uuid, text) from public, anon;
grant execute on function public.admin_price_check_request(uuid, text) to authenticated;

create or replace function public.admin_price_check_request_cancel(p_venue uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  update public.price_checks set status = 'cancelled', done_at = now()
   where venue_id = p_venue and status = 'requested';
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_price_check_request_cancel(uuid) from public, anon;
grant execute on function public.admin_price_check_request_cancel(uuid) to authenticated;

-- The requests, as lines to paste into a session: the space, its
-- page, its own website and what we show today.
create or replace function public.admin_price_check_requests()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', v.name, 'slug', v.webflow_slug, 'page', public.product_page_url(v),
      'website', v.website, 'note', r.note,
      'products', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', left(p.id::text, 8), 'name', p.name, 'label', p.price_label,
                      'category', p.category)
                      order by p.position, p.name), '[]'::jsonb)
                     from public.venue_products p
                    where p.venue_id = v.id and p.status = 'live'))
      order by r.requested_at), '[]'::jsonb)
    into out
    from public.price_checks r
    join public.venues v on v.id = r.venue_id
   where r.status = 'requested';
  return out;
end $$;
revoke all on function public.admin_price_check_requests() from public, anon;
grant execute on function public.admin_price_check_requests() to authenticated;

-- Go: this change goes on the public page (within minutes). With
-- p_final, the founder's own version of it goes instead.
create or replace function public.admin_product_change_go(p_id uuid, p_final jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c   public.product_changes%rowtype;
  fin jsonb;
  why text;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into c from public.product_changes where id = p_id for update;
  if not found then
    raise exception 'This change could not be found.';
  end if;
  if c.status not in ('proposed', 'failed') then
    raise exception 'This change is no longer waiting.';
  end if;
  if c.action = 'remove' then
    fin := null;
  else
    fin := case when p_final is null then coalesce(c.final, c.proposed)
                else public.product_clean(p_final, coalesce(c.final, c.proposed, c.before)) end;
    if c.action = 'add' and not (fin ? 'problem') then
      fin := fin || jsonb_build_object('starting_from', false);
    end if;
    why := public.product_problem(fin);
    if why is not null then
      raise exception '%', why;
    end if;
  end if;
  update public.product_changes
     set status = 'approved', final = fin, error = null, claimed_at = null,
         decided_at = clock_timestamp(), decided_by = public.upgrades_admin_email()
   where id = p_id;
  perform public.upgrades_nudge();
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_product_change_go(uuid, jsonb) from public, anon;
grant execute on function public.admin_product_change_go(uuid, jsonb) to authenticated;

-- Skip: leave the page as it is.
create or replace function public.admin_product_change_skip(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.product_changes%rowtype;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into c from public.product_changes where id = p_id for update;
  if not found then
    raise exception 'This change could not be found.';
  end if;
  if c.status not in ('proposed', 'failed') then
    raise exception 'This change is no longer waiting.';
  end if;
  update public.product_changes
     set status = 'skipped', decided_at = now(), decided_by = public.upgrades_admin_email()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_product_change_skip(uuid) from public, anon;
grant execute on function public.admin_product_change_skip(uuid) to authenticated;

-- Undo. On its way: taken back before it is written. Applied: the old
-- one is put back on the page. Skipped: brought back to decide again.
create or replace function public.admin_product_change_undo(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.product_changes%rowtype;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into c from public.product_changes where id = p_id for update;
  if not found then
    raise exception 'This change could not be found.';
  end if;
  if c.status = 'approved' then
    if c.claimed_at > now() - interval '10 minutes' then
      raise exception 'It is being written to the website right now. Give it a minute, then use Undo.';
    end if;
    if c.source = 'check' then
      update public.product_changes set status = 'proposed', decided_at = null,
             decided_by = null where id = p_id;
    else
      -- A founder's own change has no proposal to fall back to.
      update public.product_changes set status = 'skipped', decided_at = now()
       where id = p_id;
    end if;
    return jsonb_build_object('ok', true, 'was', 'approved');
  elsif c.status = 'applied' then
    if c.product_id is null then
      raise exception 'This change cannot be undone.';
    end if;
    if exists (select 1 from public.product_changes x
                where x.product_id = c.product_id and x.id <> c.id
                  and (x.status in ('proposed','approved','failed','undo_requested')
                       or (x.status = 'applied' and x.applied_at > c.applied_at))) then
      raise exception 'A newer change to this product is in hand; undo or decide that one first.';
    end if;
    update public.product_changes set status = 'undo_requested', error = null,
           claimed_at = null,
           decided_at = clock_timestamp(), decided_by = public.upgrades_admin_email()
     where id = p_id;
    perform public.upgrades_nudge();
    return jsonb_build_object('ok', true, 'was', 'applied');
  elsif c.status = 'skipped' then
    if c.product_id is not null and exists (select 1 from public.product_changes x
                where x.product_id = c.product_id and x.id <> c.id
                  and x.status in ('proposed','approved','failed','undo_requested')) then
      raise exception 'Another change to this product is already in hand.';
    end if;
    if c.source <> 'check' then
      raise exception 'This change cannot be brought back; make it again.';
    end if;
    update public.product_changes set status = 'proposed', decided_at = null,
           decided_by = null where id = p_id;
    return jsonb_build_object('ok', true, 'was', 'skipped');
  end if;
  raise exception 'This change cannot be undone now.';
end $$;
revoke all on function public.admin_product_change_undo(uuid) from public, anon;
grant execute on function public.admin_product_change_undo(uuid) to authenticated;

-- A founder's own change: correct a product, add one, take one off.
-- Approved as it is saved (saving is the Go), then written to the
-- page by the push like any other.
create or replace function public.admin_product_edit(
  p_venue uuid, p_product uuid, p_action text, p_json jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  pr   public.venue_products%rowtype;
  base jsonb;
  fin  jsonb;
  why  text;
  act  text := lower(coalesce(p_action, ''));
  new_ uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if act not in ('update', 'add', 'remove') then
    raise exception 'Unknown action.';
  end if;
  if not exists (select 1 from public.venues where id = p_venue) then
    raise exception 'This space could not be found.';
  end if;
  if act = 'add' then
    fin := public.product_clean(p_json, jsonb_build_object(
             'currency', (select x.currency from public.venue_products x
                           where x.venue_id = p_venue and x.status = 'live'
                             and x.currency is not null
                           group by x.currency order by count(*) desc limit 1)));
    if not (fin ? 'problem') then
      -- Which product carries the page's "starting from" price is
      -- chosen in Webflow; a new one never takes it over.
      fin := fin || jsonb_build_object('starting_from', false);
    end if;
    why := public.product_problem(fin);
    if why is not null then
      raise exception '%', why;
    end if;
    if exists (select 1 from public.venue_products x
                where x.venue_id = p_venue and x.status = 'live'
                  and lower(x.name) = lower(fin->>'name')) then
      raise exception 'A product with this name is already on the page.';
    end if;
    if exists (select 1 from public.product_changes x
                where x.venue_id = p_venue and x.action = 'add' and x.product_id is null
                  and x.status in ('proposed','approved','failed')
                  and lower(coalesce(x.final, x.proposed)->>'name') = lower(fin->>'name')) then
      raise exception 'A product with this name is already waiting to be added.';
    end if;
    insert into public.product_changes
      (venue_id, action, proposed, final, source, status, decided_at, decided_by)
    values (p_venue, 'add', fin, fin, 'founder', 'approved', clock_timestamp(),
            public.upgrades_admin_email())
    returning id into new_;
    perform public.upgrades_nudge();
    return jsonb_build_object('ok', true, 'id', new_);
  end if;

  select * into pr from public.venue_products
   where id = p_product and venue_id = p_venue;
  if not found then
    raise exception 'This product could not be found.';
  end if;
  if pr.status <> 'live' then
    raise exception 'This product is no longer on the page.';
  end if;
  if exists (select 1 from public.product_changes x
              where x.product_id = pr.id and x.status = 'undo_requested') then
    raise exception 'An undo for this product is on its way to the page; wait a minute.';
  end if;
  if exists (select 1 from public.product_changes x
              where x.product_id = pr.id and x.status = 'approved'
                and x.claimed_at > now() - interval '10 minutes') then
    raise exception 'A change to this product is being written to the website right now. Give it a minute.';
  end if;
  base := public.product_json(pr);
  if act = 'update' then
    fin := public.product_clean(p_json, base);
    why := public.product_problem(fin);
    if why is not null then
      raise exception '%', why;
    end if;
    if fin = public.product_clean('{}'::jsonb, base) then
      raise exception 'Nothing was changed.';
    end if;
  else
    fin := null;
  end if;
  -- The founder's word replaces a proposal that was waiting, and a
  -- change the push has not started on (once it has, the check just
  -- above refuses: the push claims a change before it writes).
  delete from public.product_changes x
   where x.product_id = pr.id and x.status in ('proposed','failed','approved');
  insert into public.product_changes
    (venue_id, product_id, action, before, proposed, final, source, status,
     decided_at, decided_by)
  values (p_venue, pr.id, act, base, fin, fin, 'founder', 'approved', clock_timestamp(),
          public.upgrades_admin_email())
  returning id into new_;
  perform public.upgrades_nudge();
  return jsonb_build_object('ok', true, 'id', new_);
end $$;
revoke all on function public.admin_product_edit(uuid, uuid, text, jsonb) from public, anon;
grant execute on function public.admin_product_edit(uuid, uuid, text, jsonb) to authenticated;

-- ------------------------------------------------- the website push

-- What the push has to write: changes a founder approved, and undos.
-- Each comes with the Webflow item it touches and, for a new product,
-- a sibling to copy the page's settings from.
create or replace function public.product_changes_to_apply(p_limit integer default 30)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.j order by x.at), '[]'::jsonb)
    from (
      select c.decided_at as at, jsonb_build_object(
          'id', c.id, 'action', c.action, 'status', c.status, 'source', c.source,
          'decided_at', c.decided_at,
          'before', c.before, 'final', c.final,
          'venue', jsonb_build_object(
            'id', v.id, 'name', v.name, 'webflow_cms_id', v.webflow_cms_id,
            'webflow_slug', v.webflow_slug),
          'product', (select jsonb_build_object(
                         'id', p.id, 'webflow_item_id', p.webflow_item_id,
                         'name', p.name, 'status', p.status)
                        from public.venue_products p where p.id = c.product_id),
          'sibling', (select p.webflow_item_id from public.venue_products p
                       where p.venue_id = c.venue_id and p.webflow_item_id is not null
                       order by (p.status = 'live') desc, p.position limit 1),
          'next_position', (select coalesce(max(p.position), 0) + 1
                              from public.venue_products p
                             where p.venue_id = c.venue_id)) as j
        from public.product_changes c
        join public.venues v on v.id = c.venue_id
       where c.status in ('approved', 'undo_requested')
       order by c.decided_at
       limit greatest(1, least(coalesce(p_limit, 30), 100))
    ) x
$$;
revoke all on function public.product_changes_to_apply(integer) from public, anon, authenticated;
grant execute on function public.product_changes_to_apply(integer) to service_role;

-- Called just before the write. It answers whether this change is
-- still wanted and still the one the push read (a founder may have
-- taken it back, or pressed Go on another wording), and in the same
-- step claims it: from here until product_change_done() the control
-- centre refuses to take it back or replace it, so the page and our
-- copy cannot part ways half way through. A claim lapses after ten
-- minutes, for a run that died; the next run then writes it again.
create or replace function public.product_change_begin(
  p_id uuid, p_status text, p_decided_at timestamptz)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  update public.product_changes c
     set claimed_at = now()
   where c.id = p_id and c.status = p_status
     and c.status in ('approved', 'undo_requested')
     and c.decided_at is not distinct from p_decided_at;
  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke all on function public.product_change_begin(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.product_change_begin(uuid, text, timestamptz) to service_role;

-- Put a product's fields on our copy.
create or replace function public.product_apply_json(p_id uuid, p jsonb)
returns void language sql security definer set search_path = public as $$
  update public.venue_products set
    name          = p->>'name',
    category      = p->>'category',
    amount        = (p->>'amount')::numeric,
    currency      = p->>'currency',
    price_label   = coalesce(p->>'label', ''),
    starting_from = coalesce((p->>'starting_from')::boolean, false),
    vat_included  = (p->>'vat_included')::boolean,
    details       = coalesce(p->'details', '[]'::jsonb),
    updated_at    = now()
  where id = p_id
$$;
revoke all on function public.product_apply_json(uuid, jsonb) from public, anon, authenticated;

-- The push reports back: written (or not), and for a new product the
-- Webflow item it made. Our copy follows what is now on the page.
create or replace function public.product_change_done(
  p_id uuid, p_ok boolean, p_error text default null,
  p_item text default null, p_item_slug text default null,
  p_before jsonb default null, p_after jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c    public.product_changes%rowtype;
  new_ uuid;
  src  text;
  now_ jsonb;
begin
  select * into c from public.product_changes where id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'why', 'not found');
  end if;
  src := case c.source when 'check' then 'check' when 'owner' then 'owner' else 'founder' end;

  if c.status = 'approved' then
    if not coalesce(p_ok, false) then
      update public.product_changes
         set status = 'failed', error = left(coalesce(p_error, 'failed'), 400),
             claimed_at = null
       where id = p_id;
      return jsonb_build_object('ok', true, 'status', 'failed');
    end if;
    -- What the page reads now, as the push saw it after writing; the
    -- change itself when the push did not say.
    now_ := case when p_after is not null and not (p_after ? 'problem')
                      and coalesce(p_after->>'name', '') <> ''
                 then p_after else c.final end;
    if c.action = 'update' then
      perform public.product_apply_json(c.product_id, now_);
      update public.venue_products set source = src, site_updated_at = now()
       where id = c.product_id;
    elsif c.action = 'remove' then
      update public.venue_products set status = 'removed', updated_at = now()
       where id = c.product_id;
    elsif c.action = 'add' then
      -- The daily copy from Webflow may have seen the new item first.
      select p.id into new_ from public.venue_products p
       where nullif(p_item, '') is not null and p.webflow_item_id = p_item;
    end if;
    if c.action = 'add' and new_ is not null then
      perform public.product_apply_json(new_, c.final);
      update public.venue_products set status = 'live', source = src, venue_id = c.venue_id
       where id = new_;
    elsif c.action = 'add' then
      insert into public.venue_products
        (venue_id, webflow_item_id, webflow_slug, name, category, amount, currency,
         price_label, starting_from, vat_included, details, position, status, source,
         site_updated_at)
      values
        (c.venue_id, nullif(p_item, ''), nullif(p_item_slug, ''), c.final->>'name', c.final->>'category',
         (c.final->>'amount')::numeric, c.final->>'currency', coalesce(c.final->>'label', ''),
         coalesce((c.final->>'starting_from')::boolean, false),
         (c.final->>'vat_included')::boolean, coalesce(c.final->'details', '[]'::jsonb),
         (select coalesce(max(p.position), 0) + 1 from public.venue_products p
           where p.venue_id = c.venue_id),
         'live', src, now())
      returning id into new_;
    end if;
    -- A change that came from a check carries the day and the page it
    -- was checked on.
    if c.source = 'check' and c.action <> 'remove' then
      update public.venue_products set
        checked_at    = coalesce(c.checked_on::timestamptz, now()),
        checked_url   = c.source_url,
        check_result  = 'changed',
        check_note    = c.note,
        check_seen_at = coalesce(check_seen_at, now())
      where id = coalesce(new_, c.product_id);
    end if;
    update public.product_changes
       set status = 'applied', applied_at = now(), error = null, claimed_at = null,
           product_id = coalesce(new_, product_id),
           -- What was really on the page just before, when the push
           -- read something else than we held.
           before = case when c.action = 'update' and p_before is not null
                         then p_before else before end
     where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'applied');

  elsif c.status = 'undo_requested' then
    if not coalesce(p_ok, false) then
      update public.product_changes
         set status = 'applied', claimed_at = null,
             error = left('Undo did not go through: ' || coalesce(p_error, 'failed'), 400)
       where id = p_id;
      return jsonb_build_object('ok', true, 'status', 'applied');
    end if;
    now_ := case when p_after is not null and not (p_after ? 'problem')
                      and coalesce(p_after->>'name', '') <> ''
                 then p_after else c.before end;
    if c.action = 'update' then
      perform public.product_apply_json(c.product_id, now_);
      update public.venue_products set site_updated_at = now() where id = c.product_id;
    elsif c.action = 'remove' then
      update public.venue_products set status = 'live', updated_at = now()
       where id = c.product_id;
    elsif c.action = 'add' then
      update public.venue_products set status = 'removed', updated_at = now()
       where id = c.product_id;
    end if;
    -- The page no longer says what the check found, so the product
    -- does not count as checked any more.
    if c.source = 'check' and c.action <> 'remove' then
      update public.venue_products set
        checked_at = null, checked_url = null, check_result = 'differs',
        check_note = c.note
      where id = c.product_id;
    end if;
    update public.product_changes set status = 'undone', error = null, claimed_at = null
     where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'undone');
  end if;
  return jsonb_build_object('ok', false, 'why', 'not waiting to be written');
end $$;
revoke all on function public.product_change_done(uuid, boolean, text, text, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.product_change_done(uuid, boolean, text, text, text, jsonb, jsonb) to service_role;
