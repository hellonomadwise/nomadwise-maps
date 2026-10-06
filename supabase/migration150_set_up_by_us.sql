-- Migration 150: spaces we set up ourselves are not "claimed".
--
-- Jonathan, 6 Oct 2026: SOKKOOL (a booking partner we agreed terms with
-- in person) and Neighbors and Nomads (paid for a listing the old way)
-- stood in Outreach as "Claimed their page". Neither has claimed
-- anything: we put them on Verified ourselves. They are the spaces to
-- invite to their Owner account, not ones that already came.
--
-- What changes (reading only, apart from one note):
--   * a space counts as claimed when a claim of its own went through
--     (listing_claims, paid or free), or its owner has been in the
--     Owner account. Everything else with an owner or on Verified is
--     "set up by us, not claimed yet": its own number on the path
--     ("ours"), its own list, and out of Claimed, "not signed in yet"
--     and On Verified;
--   * each row says which it is ("mine" in its owner part), and the
--     chips count them apart ("ours"), out of Claimed and Verified;
--   * for a space with no claim on record, a sign-in alone no longer
--     counts as "has been in the Owner account": that address may have
--     used the map long before we put it on the space. Opening the
--     Owner account, or doing anything in it, does count;
--   * the Money card's "pages claimed" leaves them out as well;
--   * the note written when a space gets an owner or goes Verified says
--     "Set up by us" when no claim stands behind it, and the notes
--     already written that way round are put right.
--
-- Nothing here writes to anybody, and no stage moves.

-- ------------------------------------------------ what each owner has done
-- As migration 149, plus "claimed_self". The shape of the answer
-- changes, so the function is made anew.
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
  test         boolean,       -- one of us trying things out (marked in Outreach)
  claimed_self boolean        -- a claim of their own went through (not put on by us)
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
                   -- No claim under this address. Where the space was
                   -- claimed (the owner's address put right since), any
                   -- sign-in counts, as before. Where we set the space
                   -- up ourselves there is no "since" to count from:
                   -- a sign-in to the map, perhaps long ago, says
                   -- nothing about the Owner account (migration 150).
                   case when exists (
                          select 1 from public.listing_claims k
                           where k.venue_id = o.id and k.status in ('paid', 'free'))
                        then '-infinity'::timestamptz end)),
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
              and t.stage in ('claimed', 'verified')),
         exists (
           select 1 from public.listing_claims k
            where k.venue_id = o.id and k.status in ('paid', 'free'))
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

  -- "mine": they claimed it themselves, or have been in the Owner
  -- account. The rest we set up (Verified by us, or an owner put on by
  -- hand) and they have not claimed: "ours", the ones to invite.
  select jsonb_build_object(
           'claimed',     count(*) filter (where x.mine),
           'not_opened',  count(*) filter (where x.mine and not x.accessed),
           'opened',      count(*) filter (where x.accessed),
           'opened_only', count(*) filter (where x.accessed and x.did = 0),
           'used',        count(*) filter (where x.did > 0),
           'looked',      count(*) filter (where x.mine and x.looked),
           'verified',    count(*) filter (where x.mine and x.tier = 'verified'),
           'ours',        count(*) filter (where not x.mine),
           'ours_verified', count(*) filter (where not x.mine and x.tier = 'verified'))
    into own
    from (select y.*, (y.claimed_self or y.accessed) as mine
            from (select a.*,
                         (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
                         (a.signed_in_at is not null or a.opens > 0
                          or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
                    from public.outreach_owner_activity() a
                   where not a.test) y) x;

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
      select y.*, (y.claimed_self or y.accessed) as mine
        from (select a.*,
                     (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
                     (a.signed_in_at is not null or a.opens > 0
                      or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
                from public.outreach_owner_activity() a) y
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
                 'last_did', a.last_did, 'looked', a.looked, 'checkout', a.checkout,
                 -- false: we set this space up and they have not claimed it
                 'mine', a.mine) end as owner
          from public.space_contacts c
          left join public.venues v on v.id = c.venue_id
          left join act a on a.venue_id = c.venue_id and c.stage in ('claimed', 'verified')
         -- a line marked as a test shows under "Tests" and nowhere else
         where (case when st = '' and coalesce(p_stage, '') = 'tests'
                     then c.is_test else not c.is_test end)
           -- the chips: "Set up by us" has its own, and those lines are
           -- not under Claimed or Verified
           and (st <> '' or coalesce(p_stage, '') in ('', 'tests')
                or (p_stage = 'ours' and coalesce(not a.mine, false))
                or (c.stage = p_stage
                    and not (p_stage in ('claimed', 'verified') and coalesce(not a.mine, false))))
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
                  when 'claimed'     then coalesce(a.mine, false)
                  when 'not_opened'  then coalesce(a.mine and not a.accessed, false)
                  when 'ours'        then coalesce(not a.mine, false)
                  when 'opened'      then coalesce(a.accessed, false)
                  when 'opened_only' then coalesce(a.accessed and a.did = 0, false)
                  when 'used'        then coalesce(a.did > 0, false)
                  when 'looked'      then coalesce(a.mine and a.looked, false)
                  when 'verified'    then coalesce(a.mine and a.tier = 'verified', false)
                  else false end)
         order by no_email, sort_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer, text, text) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer, text, text) to authenticated;

-- ------------------------------------------------ the chips' numbers
create or replace function public.admin_outreach_counts(p_group text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  -- Spaces we set up and nobody has claimed (see admin_outreach_path)
  -- are counted as "ours", not as Claimed or Verified.
  with ours as materialized (
    select a.venue_id from public.outreach_owner_activity() a
     where not (a.claimed_self or a.signed_in_at is not null or a.opens > 0
                or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0)
  )
  select case when public.is_admin() then
    coalesce((select jsonb_object_agg(stage, n)
                from (select case when c.stage in ('claimed', 'verified')
                                   and c.venue_id in (select o.venue_id from ours o)
                                  then 'ours' else c.stage end as stage,
                             count(distinct case when c.stage in ('claimed', 'verified')
                                                 then coalesce(c.venue_id, c.id) else c.id end) n
                        from public.space_contacts c
                       where not c.is_test
                         and (coalesce(p_group, '') = '' or public.outreach_group(c.source) = p_group)
                       group by 1) x), '{}'::jsonb)
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

-- ------------------------------------------------ the Money card
-- As migration 149; "pages claimed" (and "on a claimed page") leave
-- out the spaces we set up ourselves.
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
  -- Spaces we set up and nobody has claimed (migration 150): they
  -- have an owner on record, but are not "pages claimed".
  ours as materialized (
    select a.venue_id from public.outreach_owner_activity() a
     where not (a.claimed_self or a.signed_in_at is not null or a.opens > 0
                or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0)
  ),
  marked as (
    select v.website_status, v.listing_tier,
           (btrim(coalesce(v.listing_owner_email, '')) <> ''
            and not exists (select 1 from ours o where o.venue_id = v.id)) as owned,
           (btrim(coalesce(v.listing_owner_email, '')) <> '') as has_owner,
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
           count(*) filter (where v.test and (v.has_owner or v.listing_tier = 'verified'))
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

-- ------------------------------------------------ the note when a space gets an owner
create or replace function public.outreach_owner_sync(p_venue uuid, p_today boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  v        public.venues%rowtype;
  em       text;
  want     text;
  cid      uuid;      -- the contact for this space
  eid      uuid;      -- the contact with the owner's address
  evenue   uuid;
  at_      timestamptz;
  line     text;
  r        record;
  did      text := 'kept';
begin
  select * into v from public.venues where id = p_venue;
  if not found then return 'no space'; end if;
  em := nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '');

  -- ---------------------------------------------- no owner (any more)
  if em is null and coalesce(v.listing_tier, 'free') <> 'verified' then
    update public.space_contacts c
       set stage = case when c.unsubscribed_at is not null then 'unsubscribed' else 'not_now' end,
           notes = concat_ws(E'\n', nullif(c.notes, ''),
                             'Owner taken off ' || coalesce(v.name, 'the space') || ' on '
                             || to_char(now(), 'DD Mon YYYY') || '.')
     where c.venue_id = v.id and c.stage in ('claimed', 'verified');
    if found then return 'owner gone'; end if;
    return 'no owner';
  end if;

  want := case when coalesce(v.listing_tier, 'free') = 'verified' then 'verified' else 'claimed' end;

  -- When they claimed, for the note: the claim's own date; today when
  -- this runs as the owner is put on; otherwise unknown, and no date
  -- is written.
  select max(coalesce(k.approved_at, k.paid_at)) into at_
    from public.listing_claims k
   where k.venue_id = v.id and k.status in ('paid', 'free');
  if at_ is null and p_today then at_ := now(); end if;
  -- A space we put on Verified ourselves, or gave an owner by hand,
  -- has not claimed anything, and the note says so. A claim stands
  -- behind it when one that went through, or is going through right
  -- now, is on record for this space (or, for a space the claim itself
  -- added, under the owner's address). A claim that was dropped or
  -- turned down does not count.
  line := case when exists (
                 select 1 from public.listing_claims k
                  where (k.status in ('paid', 'free', 'free_pending', 'awaiting_approval')
                         and (k.venue_id = v.id
                              or (k.venue_id is null and em is not null
                                  and lower(btrim(k.owner_email)) = em)))
                     or (k.status = 'started' and k.venue_id = v.id
                         and em is not null and lower(btrim(k.owner_email)) = em))
               then 'Claimed ' else 'Set up by us: ' end
          || coalesce(v.name, 'their page')
          || coalesce(' on ' || to_char(at_, 'DD Mon YYYY'), '') || '.';

  -- The contact with the owner's address, when it is free to stand for
  -- this space (it has no space yet, or this one).
  if em is not null then
    select c.id, c.venue_id into eid, evenue
      from public.space_contacts c where lower(c.email) = em;
    if eid is not null and evenue is not null and evenue <> v.id then
      eid := null;            -- that person's contact is another space's
    end if;
  end if;

  if eid is not null then
    -- A contact made by itself for the listed space, never written to
    -- and with nothing noted, is folded into the owner's contact: one
    -- space, one line.
    for r in
      select c.* from public.space_contacts c
       where c.venue_id = v.id and c.id <> eid
    loop
      if r.source = 'listing' and r.last_in_at is null and r.last_out_at is null
         and coalesce(btrim(r.notes), '') = ''
         and not exists (select 1 from public.outreach_messages m where m.contact_id = r.id) then
        update public.space_contacts c
           set website   = coalesce(c.website, r.website),
               instagram = coalesce(c.instagram, r.instagram),
               kind      = coalesce(c.kind, r.kind),
               city      = coalesce(c.city, r.city),
               country   = coalesce(c.country, r.country)
         where c.id = eid;
        delete from public.space_contacts c where c.id = r.id;
      end if;
    end loop;
    update public.space_contacts c
       set venue_id = v.id,
           notes = case when c.stage in ('claimed', 'verified') then c.notes
                        else concat_ws(E'\n', nullif(c.notes, ''), line) end,
           -- A line made for the listed space is no longer "unclaimed".
           source = case when c.source = 'listing' then 'claim' else c.source end,
           stage = want
     where c.id = eid
       and (c.stage <> want or c.venue_id is distinct from v.id or c.source = 'listing');
    if found then did := want; end if;
  end if;

  -- Every (other) contact for this space follows it.
  update public.space_contacts c
     set notes = case when c.stage in ('claimed', 'verified') then c.notes
                      else concat_ws(E'\n', nullif(c.notes, ''), line) end,
         -- A line made for the listed space is no longer "unclaimed".
         source = case when c.source = 'listing' then 'claim' else c.source end,
         -- The owner's address, when the contact has none and nobody
         -- else holds it.
         email = case when c.email is null and em is not null
                       and c.id = (select c2.id from public.space_contacts c2
                                    where c2.venue_id = v.id
                                    order by c2.created_at, c2.id limit 1)
                       and not exists (select 1 from public.space_contacts c3
                                        where lower(c3.email) = em)
                      then em else c.email end,
         stage = want
   where c.venue_id = v.id
     and (eid is null or c.id <> eid)
     and (c.stage <> want or c.source = 'listing'
          -- at the right stage already, and the owner's address has
          -- only now come (a plan set by hand first, say)
          or (c.email is null and em is not null
              and c.id = (select c2.id from public.space_contacts c2
                           where c2.venue_id = v.id
                           order by c2.created_at, c2.id limit 1)
              and not exists (select 1 from public.space_contacts c3
                               where lower(c3.email) = em)));
  if found then did := want; end if;

  -- Nobody yet: the space gets its line.
  select c.id into cid from public.space_contacts c where c.venue_id = v.id limit 1;
  if cid is null then
    insert into public.space_contacts
      (venue_id, space_name, kind, city, country, person_name, email,
       website, instagram, source, stage, stage_at, notes)
    values
      (v.id, v.name, v.type, nullif(btrim(v.city), ''), nullif(btrim(v.country), ''),
       nullif(btrim(v.listing_owner_name), ''),
       case when em is not null
             and not exists (select 1 from public.space_contacts c where lower(c.email) = em)
            then em end,
       nullif(btrim(v.website), ''), nullif(btrim(v.instagram), ''),
       'claim', want, coalesce(at_, now()), line);
    did := 'added ' || want;
  end if;
  return did;
end $$;
revoke all on function public.outreach_owner_sync(uuid, boolean) from public, anon, authenticated;
grant execute on function public.outreach_owner_sync(uuid, boolean) to service_role;

-- ------------------------------------------------ notes already written
-- "Claimed <space>." on a line whose space never claimed becomes
-- "Set up by us: <space>." (with its date, when it had one). Only that
-- one line of the note is touched.
do $$
declare
  r   record;
  pre text;
  out text;
begin
  for r in
    select c.id, c.notes, coalesce(v.name, 'their page') as name
      from public.space_contacts c
      join public.venues v on v.id = c.venue_id
     where c.stage in ('claimed', 'verified')
       and c.notes like '%Claimed %'
       and not exists (select 1 from public.listing_claims k
                        where k.venue_id = v.id and k.status in ('paid', 'free'))
       -- an owner who has been in the Owner account did claim it
       and not exists (select 1 from public.outreach_owner_activity() a
                        where a.venue_id = v.id
                          and (a.signed_in_at is not null or a.opens > 0
                               or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0))
  loop
    pre := 'Claimed ' || r.name;
    select string_agg(
             case when t.ln = pre || '.'
                    or (length(t.ln) = length(pre) + 16
                        and left(t.ln, length(pre) + 4) = pre || ' on '
                        and right(t.ln, 1) = '.')
                  then 'Set up by us: ' || r.name || substr(t.ln, length(pre) + 1)
                  else t.ln end,
             E'\n' order by t.ord)
      into out
      from unnest(string_to_array(r.notes, E'\n')) with ordinality as t(ln, ord);
    if out is distinct from r.notes then
      update public.space_contacts set notes = out where id = r.id;
    end if;
  end loop;
end $$;
