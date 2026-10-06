-- ============================================================
-- Migration 149: test accounts are marked, and left out of the counts.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Oct 2026, looking at "The path" in Outreach saying 12
-- claimed: "the number of claimed isn't correct, as a bunch of these
-- are test accounts so were either me or Leonie. I need to be able to
-- mark tests so they get excluded."
--
-- A line in Outreach can now be marked as a test (the card's menu).
--   * Marking a claimed space marks every line of that space, and
--     every space claimed with the same owner address: the address is
--     the test, not one page.
--   * A test shows under the "Tests" chip and nowhere else. It is left
--     out of the chips' numbers, of "The path", of the number beside
--     Outreach in the menu, and of the Money card's "claimed" and
--     "Verified". Money that was really paid is still counted.
--   * The mark is about the owner. When a space's owner changes or is
--     taken off, the space's own lines stop being tests.
--   * Marked by itself, once, here and whenever an owner is put on a
--     space: an address at nomadwise.io, a founder's or team member's
--     own sign-in address (with or without a +tag), and a person named
--     just "Test" or "Test Test". Any of these can be unmarked by
--     hand, and a choice made by hand is never changed back.
-- ============================================================

alter table public.space_contacts
  add column if not exists is_test boolean not null default false,
  add column if not exists test_by text;      -- 'auto' or 'hand'
create index if not exists space_contacts_test_idx
  on public.space_contacts (venue_id) where is_test;

-- An address or a name that is plainly one of us trying things out.
create or replace function public.outreach_auto_test_email(p_email text, p_name text default null)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(lower(btrim(p_email)) like '%@nomadwise.io', false)
      or coalesce(btrim(p_name) ~* '^test(\s+test)?$', false)
      or (coalesce(btrim(p_email), '') <> '' and exists (
            select 1
              from auth.users u
              join public.profiles p on p.id = u.id
             where (coalesce(p.is_admin, false) or p.cohort = 'team')
               -- "name+anything@" is the same inbox as "name@"
               and regexp_replace(lower(btrim(u.email)), '\+[^@]*@', '@')
                 = regexp_replace(lower(btrim(p_email)), '\+[^@]*@', '@')));
$$;
revoke all on function public.outreach_auto_test_email(text, text) from public, anon, authenticated;
grant execute on function public.outreach_auto_test_email(text, text) to service_role;

-- One space: when its owner is plainly a test, or was marked as one on
-- another line, its claimed lines are marked too. A line somebody set
-- by hand is left as it was set.
create or replace function public.outreach_auto_test(p_venue uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v    public.venues%rowtype;
  em   text;
  is_t boolean;
begin
  select * into v from public.venues where id = p_venue;
  if not found then return false; end if;
  em := nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '');
  if em is null then return false; end if;
  -- "Not a test", said by hand on one of the space's claimed lines,
  -- holds for the space.
  if exists (select 1 from public.space_contacts h
              where h.venue_id = v.id and h.test_by = 'hand' and not h.is_test
                and h.stage in ('claimed', 'verified')) then
    return false;
  end if;
  is_t := public.outreach_auto_test_email(em, v.listing_owner_name)
       -- marked by hand on one of its claimed lines: the rest follow
       or exists (select 1 from public.space_contacts x
                   where x.venue_id = v.id and x.is_test and x.test_by = 'hand'
                     and x.stage in ('claimed', 'verified'))
       or exists (select 1 from public.space_contacts x
                   where x.is_test and lower(x.email) = em)
       or exists (select 1
                    from public.space_contacts x
                    join public.venues v2 on v2.id = x.venue_id
                   where x.is_test and x.stage in ('claimed', 'verified')
                     and v2.id <> v.id
                     and lower(btrim(v2.listing_owner_email)) = em);
  if is_t then
    update public.space_contacts x
       set is_test = true, test_by = 'auto'
     where x.venue_id = v.id and x.stage in ('claimed', 'verified')
       and not x.is_test and x.test_by is distinct from 'hand';
  end if;
  return is_t;
end $$;
revoke all on function public.outreach_auto_test(uuid) from public, anon, authenticated;
grant execute on function public.outreach_auto_test(uuid) to service_role;

-- A new line that is plainly one of us (a form we filled in to try
-- it) is marked as it arrives. It never stops the line from arriving.
create or replace function public.outreach_test_on_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    if not new.is_test and new.test_by is null
       and public.outreach_auto_test_email(new.email, new.person_name) then
      new.is_test := true;
      new.test_by := 'auto';
    end if;
  exception when others then
    null;
  end;
  return new;
end $$;
drop trigger if exists outreach_test_on_insert on public.space_contacts;
create trigger outreach_test_on_insert before insert on public.space_contacts
  for each row execute function public.outreach_test_on_insert();

-- The card's "Mark as a test" and "Not a test". Returns how many
-- lines changed sides.
create or replace function public.admin_outreach_set_test(p_id uuid, p_on boolean)
returns integer language plpgsql security definer set search_path = public as $$
declare
  k  public.space_contacts%rowtype;
  em text;
  n  integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into k from public.space_contacts where id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
  -- A claimed space: the owner's address is what is being marked.
  if k.stage in ('claimed', 'verified') and k.venue_id is not null then
    select nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '') into em
      from public.venues v where v.id = k.venue_id;
  end if;
  with mine as (
    select x.id, x.is_test
      from public.space_contacts x
     where x.id = k.id
        -- every line of the same claimed space
        or (k.stage in ('claimed', 'verified') and k.venue_id is not null
            and x.venue_id = k.venue_id and x.stage in ('claimed', 'verified'))
        -- every space claimed with the same owner address
        or (em is not null and x.stage in ('claimed', 'verified')
            and x.venue_id in (select v2.id from public.venues v2
                                where lower(btrim(v2.listing_owner_email)) = em))
        -- and the line that holds that address
        or (em is not null and lower(x.email) = em)
  ), done as (
    update public.space_contacts x
       set is_test = coalesce(p_on, false), test_by = 'hand'
      from mine m
     where x.id = m.id
    returning (m.is_test is distinct from coalesce(p_on, false)) as changed
  )
  select count(*) filter (where changed) into n from done;
  return coalesce(n, 0);
end $$;
revoke all on function public.admin_outreach_set_test(uuid, boolean) from public, anon;
grant execute on function public.admin_outreach_set_test(uuid, boolean) to authenticated;

-- The trigger of migration 147, now also checking for a test owner.
create or replace function public.outreach_on_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if btrim(coalesce(new.listing_owner_email, '')) <> ''
       or coalesce(new.listing_tier, 'free') = 'verified' then
      perform public.outreach_owner_sync(new.id, true);
      perform public.outreach_auto_test(new.id);
    end if;
  elsif new.listing_owner_email is distinct from old.listing_owner_email
     or new.listing_tier is distinct from old.listing_tier then
    -- The owner's address changed: a test mark was about the owner
    -- before. A test line that is not the space's claimed line lets go
    -- of the space, so it cannot follow the next claim; and the
    -- space's other lines are no longer tests.
    if lower(btrim(coalesce(new.listing_owner_email, '')))
       <> lower(btrim(coalesce(old.listing_owner_email, ''))) then
      update public.space_contacts c
         set venue_id = null
       where c.venue_id = new.id and c.is_test
         and c.stage not in ('claimed', 'verified');
      update public.space_contacts c
         set is_test = false, test_by = null
       where c.venue_id = new.id and c.is_test
         and lower(coalesce(c.email, ''))
             <> lower(btrim(coalesce(old.listing_owner_email, '')));
    end if;
    -- One owner replaced by another (a second claim approved, or the
    -- address corrected): the line with the previous owner's address
    -- steps aside and lets go of the space.
    if btrim(coalesce(old.listing_owner_email, '')) <> ''
       and btrim(coalesce(new.listing_owner_email, '')) <> ''
       and lower(btrim(old.listing_owner_email)) <> lower(btrim(new.listing_owner_email)) then
      update public.space_contacts c
         set stage = case when c.unsubscribed_at is not null then 'unsubscribed' else 'not_now' end,
             venue_id = null,
             notes = concat_ws(E'\n', nullif(c.notes, ''),
                               'No longer the owner of ' || coalesce(new.name, 'the space') || ' on '
                               || to_char(now(), 'DD Mon YYYY') || '.')
       where c.venue_id = new.id
         and lower(c.email) = lower(btrim(old.listing_owner_email))
         and c.stage in ('claimed', 'verified');
    end if;
    perform public.outreach_owner_sync(new.id, true);
    perform public.outreach_auto_test(new.id);
  end if;
  return new;
exception when others then
  -- Outreach is bookkeeping: it never stops a claim or a payment from
  -- being saved. (Two approvals at the same instant for one address
  -- could otherwise trip the one-contact-per-address rule.)
  raise warning 'outreach_on_owner(%): %', new.id, sqlerrm;
  return new;
end $$;

-- ------------------------------------------------ the tabs' numbers
-- As migration 147, with tests left out and counted by themselves.
create or replace function public.admin_outreach_counts(p_group text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then
    coalesce((select jsonb_object_agg(stage, n)
                from (select stage,
                             count(distinct case when stage in ('claimed', 'verified')
                                                 then coalesce(venue_id, id) else id end) n
                        from public.space_contacts
                       where not is_test
                         and (coalesce(p_group, '') = '' or public.outreach_group(source) = p_group)
                       group by stage) x), '{}'::jsonb)
    || jsonb_build_object(
         '_wrote',    (select count(*) from public.space_contacts
                        where not is_test and public.outreach_group(source) = 'wrote'),
         '_listed',   (select count(*) from public.space_contacts
                        where not is_test and public.outreach_group(source) = 'listed'),
         '_prospect', (select count(*) from public.space_contacts
                        where not is_test and public.outreach_group(source) = 'prospect'),
         '_no_email', (select count(*) from public.space_contacts
                        where not is_test and email is null
                          and (coalesce(p_group, '') = '' or public.outreach_group(source) = p_group)),
         '_tests',    (select count(*) from public.space_contacts
                        where is_test
                          and (coalesce(p_group, '') = '' or public.outreach_group(source) = p_group)))
  end;
$$;
revoke all on function public.admin_outreach_counts(text) from public, anon;
grant execute on function public.admin_outreach_counts(text) to authenticated;

-- ------------------------------------------------ what each owner has done
-- As migration 148, plus "test". The shape of the answer changes, so
-- the function is made anew.
drop function if exists public.outreach_owner_activity();
create or replace function public.outreach_owner_activity()
returns table (
  venue_id     uuid,
  owner_email  text,
  tier         text,
  signed_in_at timestamptz,   -- their last sign-in since they claimed
  opens        integer,       -- Owner account openings since counting began
  open_days    integer,
  last_open    timestamptz,
  edits        integer,       -- rounds of changes they started
  submitted    integer,       -- times they sent changes for review
  answers      integer,       -- questions answered
  ideas        integer,       -- ideas voted on or suggested
  billing      integer,       -- billing actions (card, cancel, resume)
  last_did     timestamptz,
  looked       boolean,       -- opened the Verified payment step, not paid
  checkout     boolean,       -- got as far as Stripe's page
  test         boolean        -- one of us trying things out (marked in Outreach)
) language sql stable security definer set search_path = public as $$
  with o as (
    select v.id,
           nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '') as em,
           coalesce(v.listing_tier, 'free') as tier
      from public.venues v
     where btrim(coalesce(v.listing_owner_email, '')) <> ''
        or coalesce(v.listing_tier, 'free') = 'verified'
  )
  select o.id, o.em, o.tier,
         -- A sign-in from their claim on: an address that used the
         -- map long before claiming has not been in the Owner account.
         (select max(u.last_sign_in_at) from auth.users u
           where lower(btrim(u.email)) = o.em
             and u.last_sign_in_at >= coalesce(
                   (select min(k.created_at) from public.listing_claims k
                     where k.venue_id = o.id and lower(btrim(k.owner_email)) = o.em),
                   '-infinity'::timestamptz)),
         coalesce((select sum(w.opens) from public.owner_visits w
                    where w.venue_id = o.id and w.owner_email = o.em), 0)::integer,
         (select count(*) from public.owner_visits w
           where w.venue_id = o.id and w.owner_email = o.em)::integer,
         (select max(w.last_at) from public.owner_visits w
           where w.venue_id = o.id and w.owner_email = o.em),
         (select count(*) from public.owner_drafts d
           where d.venue_id = o.id and lower(d.owner_email) = o.em)::integer,
         (select count(*) from public.owner_draft_events e
           where e.venue_id = o.id and lower(e.owner_email) = o.em
             and e.status = 'submitted')::integer,
         (select count(*) from public.owner_answers a
           where a.venue_id = o.id and lower(a.owner_email) = o.em
             and not a.skipped)::integer,
         ((select count(*) from public.owner_idea_votes x
            where x.venue_id = o.id and lower(x.owner_email) = o.em)
          + (select count(*) from public.owner_idea_suggestions s
              where s.venue_id = o.id and lower(s.owner_email) = o.em))::integer,
         (select count(*) from public.owner_billing_events b
           where b.venue_id = o.id and lower(b.owner_email) = o.em)::integer,
         (select max(t) from (
            select max(d.created_at) as t from public.owner_drafts d
             where d.venue_id = o.id and lower(d.owner_email) = o.em
            union all
            select max(e.created_at) from public.owner_draft_events e
             where e.venue_id = o.id and lower(e.owner_email) = o.em and e.status = 'submitted'
            union all
            select max(a.created_at) from public.owner_answers a
             where a.venue_id = o.id and lower(a.owner_email) = o.em and not a.skipped
            union all
            select max(x.created_at) from public.owner_idea_votes x
             where x.venue_id = o.id and lower(x.owner_email) = o.em
            union all
            select max(s.created_at) from public.owner_idea_suggestions s
             where s.venue_id = o.id and lower(s.owner_email) = o.em
            union all
            select max(b.created_at) from public.owner_billing_events b
             where b.venue_id = o.id and lower(b.owner_email) = o.em) z),
         o.tier <> 'verified' and exists (
           select 1 from public.listing_claims k
            where k.venue_id = o.id and lower(btrim(k.owner_email)) = o.em
              and k.plan = 'verified' and k.status in ('started', 'abandoned')),
         o.tier <> 'verified' and exists (
           select 1 from public.listing_claims k
            where k.venue_id = o.id and lower(btrim(k.owner_email)) = o.em
              and k.plan = 'verified' and k.status in ('started', 'abandoned')
              and k.billing_period is not null),
         exists (
           select 1 from public.space_contacts t
            where t.venue_id = o.id and t.is_test
              and t.stage in ('claimed', 'verified'))
    from o;
$$;
revoke all on function public.outreach_owner_activity() from public, anon, authenticated;
grant execute on function public.outreach_owner_activity() to service_role;

-- ------------------------------------------------ the numbers for the picture
create or replace function public.admin_outreach_path()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  reach  jsonb;
  own    jsonb;
  paying integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;

  select jsonb_build_object(
           'no_email',    count(*) filter (where c.stage = 'new' and c.email is null),
           'ready',       count(*) filter (where c.stage = 'new' and c.email is not null),
           'waiting',     count(*) filter (where c.stage = 'contacted'),
           'follow_up',   count(*) filter (where public.outreach_follow_up_due(
                                                   c.stage, c.follow_up_on, c.last_out_at)),
           'replied',     count(*) filter (where c.stage = 'replied'),
           'stepped_off', count(*) filter (where c.stage in
                                             ('not_now', 'declined', 'unsubscribed', 'bounced')))
    into reach
    from public.space_contacts c
   where not c.is_test;

  select jsonb_build_object(
           'claimed',     count(*),
           'not_opened',  count(*) filter (where not x.accessed),
           'opened',      count(*) filter (where x.accessed),
           'opened_only', count(*) filter (where x.accessed and x.did = 0),
           'used',        count(*) filter (where x.did > 0),
           'looked',      count(*) filter (where x.looked),
           'verified',    count(*) filter (where x.tier = 'verified'))
    into own
    from (select a.*,
                 (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
                 (a.signed_in_at is not null or a.opens > 0
                  or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
            from public.outreach_owner_activity() a
           where not a.test) x;

  -- Paying, as the Money card counts it.
  begin
    paying := (public.admin_money() ->> 'paying')::integer;
  exception when others then
    paying := null;
  end;

  return jsonb_build_object(
    'reach', reach,
    'owners', own,
    'paying', paying,
    -- lines marked as tests, left out of every number above
    'tests', (select count(*) from public.space_contacts c where c.is_test),
    'visits_since', (select s.value #>> '{}' from public.sync_settings s
                      where s.key = 'owner_visits_since'));
end $$;
revoke all on function public.admin_outreach_path() from public, anon;
grant execute on function public.admin_outreach_path() to authenticated;

-- ------------------------------------------------ the list
create or replace function public.admin_outreach_list(
  p_stage text default null, p_q text default null, p_limit integer default 200,
  p_group text default null, p_step text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  q  text := lower(trim(coalesce(p_q, '')));
  st text := coalesce(nullif(btrim(p_step), ''), '');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    with act as materialized (
      select a.*,
             (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
             (a.signed_in_at is not null or a.opens > 0
              or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
        from public.outreach_owner_activity() a
    )
    select jsonb_agg(row_to_json(x)::jsonb order by x.no_email, x.sort_at desc)
      from (
        select c.id, c.venue_id, c.space_name, c.kind, c.city, c.country,
               c.person_name, c.email, c.phone, c.website, c.instagram,
               c.source, c.form_name, c.stage, c.stage_at, c.first_in_at,
               c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.unsubscribed_at, c.is_test,
               (c.email is null) as no_email,
               greatest(coalesce(c.last_in_at, c.created_at), coalesce(c.last_out_at, c.created_at), c.stage_at) as sort_at,
               v.name as venue_name, v.city as venue_city, v.country as venue_country,
               v.webflow_slug, (v.webflow_cms_id is not null) as on_site,
               v.listing_tier, v.listing_owner_email,
               (select m.body from public.outreach_messages m
                 where m.contact_id = c.id and m.direction = 'in'
                 order by m.at desc limit 1) as last_in,
               (select count(*) from public.outreach_messages m where m.contact_id = c.id) as message_count,
               case when a.venue_id is not null then jsonb_build_object(
                 'signed_in_at', a.signed_in_at, 'accessed', a.accessed,
                 'opens', a.opens, 'open_days', a.open_days, 'last_open', a.last_open,
                 'edits', a.edits, 'submitted', a.submitted, 'answers', a.answers,
                 'ideas', a.ideas, 'billing', a.billing, 'did', a.did,
                 'last_did', a.last_did, 'looked', a.looked, 'checkout', a.checkout) end as owner
          from public.space_contacts c
          left join public.venues v on v.id = c.venue_id
          left join act a on a.venue_id = c.venue_id and c.stage in ('claimed', 'verified')
         -- a line marked as a test shows under "Tests" and nowhere else
         where (case when st = '' and coalesce(p_stage, '') = 'tests'
                     then c.is_test else not c.is_test end)
           and (st <> '' or coalesce(p_stage, '') in ('', 'tests') or c.stage = p_stage)
           and (st <> '' or coalesce(p_group, '') = '' or public.outreach_group(c.source) = p_group)
           and (q = '' or lower(coalesce(c.space_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.email, '')) like '%' || q || '%'
                       or lower(coalesce(c.person_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.city, '')) like '%' || q || '%'
                       or lower(coalesce(c.country, '')) like '%' || q || '%'
                       or lower(coalesce(v.name, '')) like '%' || q || '%')
           and (st = '' or case st
                  when 'no_email'    then c.stage = 'new' and c.email is null
                  when 'ready'       then c.stage = 'new' and c.email is not null
                  when 'waiting'     then c.stage = 'contacted'
                  when 'follow_up'   then public.outreach_follow_up_due(
                                            c.stage, c.follow_up_on, c.last_out_at)
                  when 'replied'     then c.stage = 'replied'
                  when 'stepped_off' then c.stage in ('not_now', 'declined', 'unsubscribed', 'bounced')
                  when 'claimed'     then a.venue_id is not null
                  when 'not_opened'  then a.venue_id is not null and not a.accessed
                  when 'opened'      then coalesce(a.accessed, false)
                  when 'opened_only' then coalesce(a.accessed and a.did = 0, false)
                  when 'used'        then coalesce(a.did > 0, false)
                  when 'looked'      then coalesce(a.looked, false)
                  when 'verified'    then coalesce(a.tier = 'verified', false)
                  else false end)
         order by no_email, sort_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer, text, text) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer, text, text) to authenticated;

-- ------------------------------------------------ the Money card
create or replace function public.admin_money()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  out jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;

  with first_payment as (
    -- the checkout that started each subscription (ignored ones out)
    select distinct on (o.subscription_id)
           o.subscription_id, coalesce(o.amount, 0) as amount,
           upper(o.currency) as currency, o.paid_at, o.renews_at
      from public.stripe_orders o
     where coalesce(o.subscription_id, '') <> '' and o.status <> 'ignored'
     order by o.subscription_id, o.created_at desc
  ),
  -- Every subscription a checkout started or a listing carries. A
  -- stored subscription that neither points at any more (its order
  -- was ignored, its owner removed) is left out, as the Stripe job
  -- no longer reads it.
  ids as (
    select f.subscription_id from first_payment f
    union
    select v.stripe_subscription_id from public.venues v
     where coalesce(v.stripe_subscription_id, '') <> ''
  ),
  subs as (
    select i.subscription_id,
           v.id as venue_id, v.name as venue_name, v.listing_renews_at,
           coalesce(v.listing_tier = 'verified', false) as on_verified,
           coalesce(s.currency, f.currency) as currency,
           coalesce(s.period,
                    case when f.renews_at - f.paid_at > 45 then 'year' else 'month' end,
                    'month') as period,
           greatest(coalesce(s.period_count, 1), 1) as period_count,
           -- still running: Stripe's word when it has been read, else
           -- the listing still being Verified. "past_due" (a payment
           -- failed and Stripe is trying again) still runs.
           case when s.status is not null then s.status in ('active', 'past_due')
                else coalesce(v.listing_tier = 'verified', false) end as running,
           coalesce(s.status = 'past_due', false) as retrying,
           -- what one period brings in: the last payment kept once the
           -- payments were read, else the first payment at the
           -- checkout. A subscription Stripe no longer has (a test one
           -- left behind) brought in nothing.
           case when s.status = 'gone' then 0
                when s.collected is not null
                then case when s.collected > 0 then coalesce(s.last_amount, 0) else 0 end
                else coalesce(f.amount, 0) end as amount,
           case when s.status = 'gone' then 0
                when s.collected is not null then s.collected
                else coalesce(f.amount, 0) end as collected,
           (s.collected is not null or coalesce(s.status = 'gone', false)) as exact,
           coalesce(s.ends_at_period_end, false) as ending,
           s.checked_at
      from ids i
      left join public.stripe_subscriptions s on s.subscription_id = i.subscription_id
      left join first_payment f on f.subscription_id = i.subscription_id
      left join lateral (
        select v0.* from public.venues v0
         where v0.stripe_subscription_id = i.subscription_id
         order by (v0.listing_tier = 'verified') desc, v0.created_at
         limit 1) v on true
  ),
  priced as (
    select b.*,
           (b.running and b.amount > 0) as paying,
           public.money_eur_rate(b.currency) as rate,
           b.amount / (case when b.period = 'year' then 12 else 1 end * b.period_count)
             as monthly
      from subs b
  ),
  -- Spaces whose owner is one of us trying things out (marked as a
  -- test in Outreach): not counted as claimed or Verified.
  tests as (
    select distinct c.venue_id
      from public.space_contacts c
     where c.is_test and c.venue_id is not null
       and c.stage in ('claimed', 'verified')
  ),
  marked as (
    select v.website_status, v.listing_tier,
           (btrim(coalesce(v.listing_owner_email, '')) <> '') as owned,
           exists (select 1 from tests t where t.venue_id = v.id) as test
      from public.venues v
  ),
  pages as (
    select count(*) filter (where v.website_status = 'released') as live,
           count(*) filter (where v.owned and not v.test) as claimed,
           count(*) filter (where v.owned and not v.test
                              and v.website_status = 'released') as claimed_live,
           count(*) filter (where v.listing_tier = 'verified' and not v.test) as verified,
           count(*) filter (where v.listing_tier = 'verified' and v.owned and not v.test)
             as verified_claimed,
           count(*) filter (where v.test and (v.owned or v.listing_tier = 'verified'))
             as tests
      from marked v
  )
  select jsonb_build_object(
    'live', (select live from pages),
    'claimed', (select claimed from pages),
    'claimed_live', (select claimed_live from pages),
    'verified', (select verified from pages),
    'verified_claimed', (select verified_claimed from pages),
    -- test spaces left out of the four numbers above
    'tests', (select tests from pages),
    -- of "paying" below, the ones on a test space (real money, so
    -- still counted there, but not one of the Verified above)
    'paying_tests', (select count(distinct p.venue_id) from priced p
                      where p.paying and p.on_verified
                        and exists (select 1 from tests t where t.venue_id = p.venue_id)),
    -- listings that really pay
    'paying', (select count(distinct p.venue_id) from priced p
                where p.paying and p.on_verified),
    -- money coming in that no Verified listing carries yet (a payment
    -- still to match, or a listing switched back by hand)
    'paying_unmatched', (select count(*) from priced p
                          where p.paying and not p.on_verified),
    'paying_monthly', (select count(*) from priced p where p.paying and p.period = 'month'),
    'paying_yearly', (select count(*) from priced p where p.paying and p.period = 'year'),
    'ending', (select count(*) from priced p where p.paying and p.ending),
    -- paying, but the latest payment failed and Stripe is trying again
    'retrying', (select count(*) from priced p where p.paying and p.retrying),
    'mrr_eur', coalesce((select round(sum(p.monthly * p.rate), 2) from priced p
                          where p.paying and p.rate is not null), 0),
    'mrr_other', coalesce((
      select jsonb_agg(jsonb_build_object('currency', x.currency, 'amount', x.amount)
                       order by x.currency)
        from (select coalesce(p.currency, '') as currency, round(sum(p.monthly), 2) as amount
                from priced p where p.paying and p.rate is null
               group by 1) x), '[]'::jsonb),
    'collected_eur', coalesce((select round(sum(p.collected * p.rate), 2) from priced p
                                where p.collected > 0 and p.rate is not null), 0),
    'collected_other', coalesce((
      select jsonb_agg(jsonb_build_object('currency', x.currency, 'amount', x.amount)
                       order by x.currency)
        from (select coalesce(p.currency, '') as currency, round(sum(p.collected), 2) as amount
                from priced p where p.collected > 0 and p.rate is null
               group by 1) x), '[]'::jsonb),
    -- true when every payment counted was read from Stripe; false
    -- while a first payment at the checkout stands in for one
    'exact', coalesce((select bool_and(p.exact) from priced p
                        where p.collected > 0 or p.paying), true),
    'subscriptions', (select count(*) from priced),
    'checked_at', (select max(p.checked_at) from priced p),
    -- paying listings that renew in the next 30 days (not the ones
    -- set to end)
    'renewing', coalesce((
      select jsonb_agg(jsonb_build_object('name', r.venue_name, 'renews_at', r.listing_renews_at)
                       order by r.listing_renews_at, r.venue_name)
        from (select distinct p.venue_id, p.venue_name, p.listing_renews_at
                from priced p
               where p.paying and p.on_verified and not p.ending
                 and p.listing_renews_at >= current_date
                 and p.listing_renews_at < current_date + 30) r), '[]'::jsonb)
  ) into out;

  return out;
end $$;
revoke all on function public.admin_money() from public, anon;
grant execute on function public.admin_money() to authenticated;

-- ------------------------------------------------ the number beside Outreach in the menu
-- As migration 146, with tests left out of the Outreach count.
create or replace function public.admin_next_up()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  out   jsonb := '{}'::jsonb;
  part  jsonb;
  pages jsonb;
  cand  jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;

  -- Text upgrades waiting for a Go: how many, on how many pages, and
  -- the most promising page among them.
  begin
    select jsonb_build_object(
             'n', coalesce(sum(t.waiting), 0),
             'pages', count(*),
             'venue_id', (array_agg(t.id order by t.impact desc, t.name))[1],
             'name', (array_agg(t.name order by t.impact desc, t.name))[1],
             'waiting', (array_agg(t.waiting order by t.impact desc, t.name))[1])
      into part
      from (select v.id, v.name, count(*) as waiting,
                   public.upgrade_impact(v, 'description') as impact
              from public.page_upgrades u
              join public.venues v on v.id = u.venue_id
             where u.kind <> 'photos' and u.status in ('proposed', 'failed')
             group by v.id) t;
    out := out || jsonb_build_object('drafts', part);
  exception when others then
    null;
  end;

  -- Price changes waiting for a Go: the first space as Price check
  -- lists them (by name).
  begin
    select jsonb_build_object(
             'n', coalesce(sum(t.waiting), 0),
             'spaces', count(*),
             'venue_id', (array_agg(t.id order by t.name, t.id))[1],
             'name', (array_agg(t.name order by t.name, t.id))[1],
             'waiting', (array_agg(t.waiting order by t.name, t.id))[1])
      into part
      from (select v.id, v.name, count(*) as waiting
              from public.product_changes c
              join public.venues v on v.id = c.venue_id
             where c.status in ('proposed', 'failed')
             group by v.id) t;
    out := out || jsonb_build_object('prices', part);
  exception when others then
    null;
  end;

  -- Pages short of photos, as "Add photos" lists them, without the
  -- ones whose new photos are already on their way.
  begin
    select jsonb_build_object(
             'n', count(*),
             'venue_id', (array_agg(t.id order by t.impact desc, t.photos, t.name))[1],
             'name', (array_agg(t.name order by t.impact desc, t.photos, t.name))[1],
             'photos', (array_agg(t.photos order by t.impact desc, t.photos, t.name))[1])
      into part
      from (select v.id, v.name, (f.facts ->> 'photos')::int as photos,
                   public.upgrade_impact(v, 'photos') as impact
              from public.venues v
              join public.venue_page_facts f on f.venue_id = v.id
             where public.upgrade_page_is_live(v)
               and (f.facts ->> 'photos') is not null
               and (f.facts ->> 'photos')::int < 5
               and not public.upgrade_owner_photos(v)
               and not exists (select 1 from public.page_upgrades u
                                where u.venue_id = v.id and u.kind = 'photos'
                                  and u.status in ('proposed', 'approved',
                                                   'failed', 'undo_requested'))) t;
    out := out || jsonb_build_object('photos', part);
  exception when others then
    null;
  end;

  -- The first page of "Choose a page" not dealt with yet (migration
  -- 142), and how many such pages the list holds (it shows 300).
  begin
    pages := public.admin_upgrades_pages(null, null, 300);
    select jsonb_build_object(
             'n', count(*),
             'more', jsonb_array_length(pages) >= 300,
             'venue_id', (array_agg(x ->> 'venue_id' order by ord))[1],
             'name', (array_agg(x ->> 'name' order by ord))[1],
             'reason', (array_agg(x ->> 'reason' order by ord))[1])
      into part
      from jsonb_array_elements(pages) with ordinality t(x, ord)
     where (x ->> 'section')::int = 1;
    out := out || jsonb_build_object('page', part);
  exception when others then
    null;
  end;

  -- The best bet on the Candidates list, and how many wait.
  begin
    cand := public.admin_candidates(null, 1, 0, 'best');
    out := out || jsonb_build_object('candidate', jsonb_build_object(
      'n', coalesce((cand ->> 'total')::int, 0),
      'place', cand -> 'rows' -> 0 ->> 'google_place_id',
      'name', cand -> 'rows' -> 0 ->> 'name',
      'area', cand -> 'rows' -> 0 ->> 'area',
      'coworking', coalesce((cand -> 'rows' -> 0 ->> 'coworking')::boolean, false),
      'mentions', coalesce((cand -> 'rows' -> 0 ->> 'mentions')::int, 0),
      'searches', (cand -> 'rows' -> 0 ->> 'searches')::int));
  exception when others then
    null;
  end;

  -- The numbers beside the menu's other tools (migration 146): what
  -- is open in each. Each in its own block: a tool whose tables are
  -- not there says nothing, the others still do.
  declare
    n_outreach integer;
    n_review   integer;
    n_feedback integer;
  begin
    begin
      -- Outreach: a space answered and waits for a reply, or a
      -- follow-up you set has come due and nothing has been sent
      -- since that day (the date stays on the contact after sending).
      select count(*) into n_outreach
        from public.space_contacts c
       where not c.is_test
         and (c.stage = 'replied'
          or (c.follow_up_on is not null and c.follow_up_on <= current_date
              and (c.last_out_at is null
                   or c.last_out_at::date < c.follow_up_on)
              and c.stage not in ('claimed', 'verified', 'declined',
                                  'unsubscribed', 'bounced')));
    exception when others then
      n_outreach := null;
    end;
    begin
      -- Review submissions: reports waiting to be checked, and photos
      -- waiting for a yes or no.
      select count(*) filter (where s.status = 'pending')
           + count(*) filter (where s.photo_path is not null
                                and s.photo_status = 'pending')
        into n_review
        from public.submissions s;
    exception when others then
      n_review := null;
    end;
    begin
      -- Feedback inbox: messages not marked done.
      select count(*) into n_feedback
        from public.feedback f where f.status = 'new';
    exception when others then
      n_feedback := null;
    end;
    out := out || jsonb_build_object('menu', jsonb_strip_nulls(jsonb_build_object(
      'outreach', n_outreach, 'review', n_review, 'feedback', n_feedback)));
  end;

  return out;
end $$;
revoke all on function public.admin_next_up() from public, anon;
grant execute on function public.admin_next_up() to authenticated;

-- ------------------------------------------------ what is plainly a test today
-- A line whose own address or person is plainly one of us (in one
-- pass: the founders' addresses are read once, not once a line). The
-- claimed lines of a space are left to the owner check below.
update public.space_contacts x
   set is_test = true, test_by = 'auto'
 where not x.is_test and x.test_by is distinct from 'hand'
   and not (x.venue_id is not null and x.stage in ('claimed', 'verified'))
   and (coalesce(lower(btrim(x.email)) like '%@nomadwise.io', false)
     or coalesce(btrim(x.person_name) ~* '^test(\s+test)?$', false)
     or regexp_replace(lower(btrim(x.email)), '\+[^@]*@', '@') in (
          select regexp_replace(lower(btrim(u.email)), '\+[^@]*@', '@')
            from auth.users u
            join public.profiles p on p.id = u.id
           where (coalesce(p.is_admin, false) or p.cohort = 'team')
             and btrim(coalesce(u.email, '')) <> ''));

-- Every space with an owner: is the owner one of us?
do $$
declare r record;
begin
  for r in
    select v.id from public.venues v
     where btrim(coalesce(v.listing_owner_email, '')) <> ''
     order by v.name
  loop
    perform public.outreach_auto_test(r.id);
  end loop;
end $$;
