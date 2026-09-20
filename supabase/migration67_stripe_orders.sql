-- ============================================================
-- Migration 67: Stripe orders.
-- (Applied automatically by the build; nothing to paste.)
--
-- scripts/stripe_sync.py records every paid Verified checkout here
-- and matches it to a space (by the id the payment link carries, the
-- owner's email, or a nomadwise.io link the buyer typed). A matched
-- order has already set the space's plan; an unmatched one waits in
-- the control centre's Paid listings section until a founder attaches
-- it to a space with attach_stripe_order.
-- ============================================================

create table if not exists public.stripe_orders (
  id              uuid primary key default gen_random_uuid(),
  session_id      text not null unique,
  customer_id     text,
  subscription_id text,
  email           text,
  name            text,
  space_name      text,
  space_link      text,
  amount          numeric,
  currency        text,
  paid_at         date,
  renews_at       date,
  status          text not null default 'unmatched'
                  check (status in ('unmatched','matched','ignored')),
  venue_id        uuid references public.venues(id) on delete set null,
  matched_by      text,
  created_at      timestamptz not null default now()
);

alter table public.stripe_orders enable row level security;
drop policy if exists "stripe_orders admin" on public.stripe_orders;
create policy "stripe_orders admin" on public.stripe_orders
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- A founder attaches an unmatched order to a space: the plan is set
-- from the order and the page updated, exactly as an automatic match.
create or replace function public.attach_stripe_order(p_order uuid, p_venue uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  o public.stripe_orders%rowtype;
  v public.venues%rowtype;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select * into o from public.stripe_orders where id = p_order;
  if not found then raise exception 'order not found'; end if;
  select * into v from public.venues where id = p_venue;
  if not found then raise exception 'space not found'; end if;

  update public.venues set
    listing_tier = 'verified',
    listing_owner_email = coalesce(o.email, listing_owner_email),
    listing_owner_name = coalesce(o.name, listing_owner_name),
    listing_paid_at = coalesce(o.paid_at, current_date),
    listing_renews_at = coalesce(o.renews_at, coalesce(o.paid_at, current_date) + interval '1 year'),
    stripe_customer_id = coalesce(o.customer_id, stripe_customer_id),
    stripe_subscription_id = coalesce(o.subscription_id, stripe_subscription_id),
    listing_sync_requested_at = now(),
    listing_synced_at = null,
    listing_sync_error = null,
    website_status = case when webflow_cms_id is null and website_status = 'not_on_site'
                          then 'queued' else website_status end,
    website_dismissed_at = case when webflow_cms_id is null and website_status = 'not_on_site'
                                then null else website_dismissed_at end
  where id = p_venue;

  update public.stripe_orders
     set status = 'matched', venue_id = p_venue, matched_by = 'founder'
   where id = p_order;
end $$;
grant execute on function public.attach_stripe_order(uuid, uuid) to authenticated;

create or replace function public.ignore_stripe_order(p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  update public.stripe_orders set status = 'ignored' where id = p_order;
end $$;
grant execute on function public.ignore_stripe_order(uuid) to authenticated;
