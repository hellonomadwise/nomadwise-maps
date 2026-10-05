-- ============================================================
-- Migration 138: the Money line as a funnel, with real money.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026: the Money line read "6 Verified, 6 paying
-- through Stripe" when all six had been made Verified by hand and
-- nobody had paid. It counted every Verified listing with a "paid on"
-- date, and the Listing plan page fills that date in by itself. He
-- wants the line to read left to right as a funnel that starts with
-- the listings claimed, to count as paying only the listings that
-- really pay, and to show the monthly income in euros and the total
-- collected.
--
-- What this adds:
--   stripe_subscriptions  one row per Stripe subscription, written by
--                         the hourly Stripe job (scripts/
--                         stripe_money.py): what it charges and how
--                         often, whether it still runs, and what it
--                         has brought in, refunds taken off.
--   money_eur_rate()      a currency in euros, worked out from our
--                         own price list (a plan that costs 15 EUR
--                         and 13 GBP makes a pound worth 15/13 of a
--                         euro). No outside exchange rate is used.
--   admin_money()         the numbers for the card.
--
-- "Paying" means: a subscription Stripe says is running, whose last
-- payment was above zero. A listing made Verified by hand, a 100%
-- promotion code and a payment that was refunded do not count.
--
-- Until the Stripe job has read a subscription's payments (the key
-- needs "Charges and Refunds: Read" for that), its first payment at the checkout
-- stands in: right for the count and the monthly income, short of the
-- renewals for the total collected. admin_money() says which of the
-- two the total is ("exact").
--
-- Nothing here changes a listing, a plan or a page.
-- ============================================================

create table if not exists public.stripe_subscriptions (
  subscription_id    text primary key,
  customer_id        text,
  status             text,     -- Stripe's own word: active, past_due, canceled, ...
  currency           text,     -- EUR, GBP, USD, AUD
  list_amount        numeric,  -- the plan's price for one period
  period             text check (period in ('month', 'year')),
  period_count       integer not null default 1 check (period_count >= 1),
  ends_at_period_end boolean not null default false,
  period_end         date,
  -- From the payments (null until the key may read them):
  collected          numeric,  -- paid, refunds taken off, all time
  charges_paid       integer,  -- payments kept
  last_amount        numeric,  -- the last payment kept
  first_paid         date,
  last_paid          date,
  checked_at         timestamptz not null default now()
);

alter table public.stripe_subscriptions enable row level security;
drop policy if exists "stripe_subscriptions admin" on public.stripe_subscriptions;
create policy "stripe_subscriptions admin" on public.stripe_subscriptions
  for select to authenticated using (public.is_admin());

-- Which subscriptions the Stripe job should look at now: every one a
-- listing carries and every one a checkout started (ignored orders
-- left out). About once an hour, or at once when asked (a new
-- payment, a plan that ended).
create or replace function public.stripe_subscriptions_due(p_force boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  last_run timestamptz;
begin
  select s.updated_at into last_run
    from public.sync_settings s where s.key = 'stripe_money';
  if not coalesce(p_force, false)
     and last_run is not null
     and last_run > now() - interval '55 minutes' then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'subscription_id', x.subscription_id,
             'customer_id', x.customer_id)
             order by x.subscription_id)
      from (select i.subscription_id, max(i.customer_id) as customer_id
              from (select v.stripe_subscription_id as subscription_id,
                           v.stripe_customer_id as customer_id
                      from public.venues v
                     where coalesce(v.stripe_subscription_id, '') <> ''
                    union all
                    select o.subscription_id, o.customer_id
                      from public.stripe_orders o
                     where coalesce(o.subscription_id, '') <> ''
                       and o.status <> 'ignored') i
             group by i.subscription_id) x), '[]'::jsonb);
end $$;
revoke all on function public.stripe_subscriptions_due(boolean) from public, anon, authenticated;
grant execute on function public.stripe_subscriptions_due(boolean) to service_role;

-- The Stripe job writes what it found. A row without the payment
-- keys (the key may not read charges) keeps the payments recorded
-- before. Returns how many rows were kept.
create or replace function public.set_stripe_subscriptions(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer := 0;
begin
  if p is not null and jsonb_typeof(p) = 'array' then
    insert into public.stripe_subscriptions as t
      (subscription_id, customer_id, status, currency, list_amount, period,
       period_count, ends_at_period_end, period_end,
       collected, charges_paid, last_amount, first_paid, last_paid, checked_at)
    select distinct on (x.subscription_id)
           x.subscription_id, x.customer_id, x.status, x.currency, x.list_amount,
           x.period, x.period_count, x.ends_at_period_end, x.period_end,
           x.collected, x.charges_paid, x.last_amount, x.first_paid, x.last_paid, now()
      from (select btrim(e ->> 'subscription_id') as subscription_id,
                   nullif(btrim(coalesce(e ->> 'customer_id', '')), '') as customer_id,
                   nullif(lower(btrim(coalesce(e ->> 'status', ''))), '') as status,
                   nullif(upper(btrim(coalesce(e ->> 'currency', ''))), '') as currency,
                   case when (e ->> 'list_amount') ~ '^[0-9]{1,9}(\.[0-9]{1,6})?$'
                        then (e ->> 'list_amount')::numeric end as list_amount,
                   case when lower(e ->> 'period') in ('month', 'year')
                        then lower(e ->> 'period') end as period,
                   case when (e ->> 'period_count') ~ '^[1-9][0-9]{0,2}$'
                        then (e ->> 'period_count')::integer else 1 end as period_count,
                   coalesce((e ->> 'ends_at_period_end') = 'true', false) as ends_at_period_end,
                   case when (e ->> 'period_end') ~ '^\d{4}-\d{2}-\d{2}$'
                        then (e ->> 'period_end')::date end as period_end,
                   case when (e ->> 'collected') ~ '^[0-9]{1,9}(\.[0-9]{1,6})?$'
                        then (e ->> 'collected')::numeric end as collected,
                   case when (e ->> 'charges_paid') ~ '^[0-9]{1,6}$'
                        then (e ->> 'charges_paid')::integer end as charges_paid,
                   case when (e ->> 'last_amount') ~ '^[0-9]{1,9}(\.[0-9]{1,6})?$'
                        then (e ->> 'last_amount')::numeric end as last_amount,
                   case when (e ->> 'first_paid') ~ '^\d{4}-\d{2}-\d{2}$'
                        then (e ->> 'first_paid')::date end as first_paid,
                   case when (e ->> 'last_paid') ~ '^\d{4}-\d{2}-\d{2}$'
                        then (e ->> 'last_paid')::date end as last_paid
              from jsonb_array_elements(p) e
             where jsonb_typeof(e) = 'object') x
     where coalesce(x.subscription_id, '') <> ''
     order by x.subscription_id
    on conflict (subscription_id) do update
      set customer_id        = coalesce(excluded.customer_id, t.customer_id),
          status             = coalesce(excluded.status, t.status),
          currency           = coalesce(excluded.currency, t.currency),
          list_amount        = coalesce(excluded.list_amount, t.list_amount),
          period             = coalesce(excluded.period, t.period),
          period_count       = excluded.period_count,
          ends_at_period_end = excluded.ends_at_period_end,
          period_end         = coalesce(excluded.period_end, t.period_end),
          -- the payments are replaced only when they were read
          collected    = case when excluded.collected is not null
                              then excluded.collected else t.collected end,
          charges_paid = case when excluded.collected is not null
                              then excluded.charges_paid else t.charges_paid end,
          last_amount  = case when excluded.collected is not null
                              then excluded.last_amount else t.last_amount end,
          first_paid   = case when excluded.collected is not null
                              then excluded.first_paid else t.first_paid end,
          last_paid    = case when excluded.collected is not null
                              then excluded.last_paid else t.last_paid end,
          checked_at   = excluded.checked_at;
    get diagnostics n = row_count;
  end if;
  -- the job ran, whatever it found: the next look is in an hour
  insert into public.sync_settings (key, value, updated_at)
  values ('stripe_money', jsonb_build_object('rows', n), now())
  on conflict (key) do update
    set value = excluded.value, updated_at = excluded.updated_at;
  return n;
end $$;
revoke all on function public.set_stripe_subscriptions(jsonb) from public, anon, authenticated;
grant execute on function public.set_stripe_subscriptions(jsonb) to service_role;

-- One unit of a currency in euros, from our own price list: across
-- the price groups, what the plans cost in euros divided by what the
-- same plans cost in that currency. Null when no plan has a price in
-- it (the card then shows that money apart, in its own currency).
create or replace function public.money_eur_rate(p_currency text)
returns numeric language sql stable security definer set search_path = public as $$
  select case
    when upper(btrim(coalesce(p_currency, ''))) = 'EUR' then 1::numeric
    when btrim(coalesce(p_currency, '')) = '' then null
    else (
      select sum((g.amounts -> per ->> 'EUR')::numeric)
             / nullif(sum((g.amounts -> per ->> upper(btrim(p_currency)))::numeric), 0)
        from public.pricing_groups g
       cross join unnest(array['monthly', 'yearly']) as per
       where coalesce(g.amounts -> per ->> 'EUR', '') ~ '^[1-9][0-9]*$'
         and coalesce(g.amounts -> per ->> upper(btrim(p_currency)), '') ~ '^[1-9][0-9]*$')
  end
$$;
revoke all on function public.money_eur_rate(text) from public, anon, authenticated;

-- The numbers for the Money card, left to right: pages live, claimed,
-- Verified, paying, monthly income, collected.
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
  pages as (
    select count(*) filter (where v.website_status = 'released') as live,
           count(*) filter (where btrim(coalesce(v.listing_owner_email, '')) <> '') as claimed,
           count(*) filter (where btrim(coalesce(v.listing_owner_email, '')) <> ''
                              and v.website_status = 'released') as claimed_live,
           count(*) filter (where v.listing_tier = 'verified') as verified,
           count(*) filter (where v.listing_tier = 'verified'
                              and btrim(coalesce(v.listing_owner_email, '')) <> '')
             as verified_claimed
      from public.venues v
  )
  select jsonb_build_object(
    'live', (select live from pages),
    'claimed', (select claimed from pages),
    'claimed_live', (select claimed_live from pages),
    'verified', (select verified from pages),
    'verified_claimed', (select verified_claimed from pages),
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
