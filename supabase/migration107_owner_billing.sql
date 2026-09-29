-- ============================================================
-- Migration 107: Plan & billing, self-serve, in the Owner account.
-- (Applied automatically by the build. One setting to add by hand:
--  the Stripe key in the Vault, see docs/BILLING.md.)
--
-- Owners manage their plan without writing to us:
--   * see their plan, its status, the next payment and the card on it
--   * every invoice and receipt, to view or download
--   * cancel renewal (with an optional reason) and undo it, in place
--   * update the card and billing details on Stripe's secure page,
--     opened straight at the right step (no second login)
-- Everything is read live from Stripe, so it is never out of date.
--
-- How: Postgres calls Stripe directly (the http extension) with a
-- restricted key kept in the Vault as 'stripe_billing_key'. Until the
-- key is there, the account shows the plan from our own records and
-- says billing tools are being connected; nothing breaks.
-- Cancellations and resumes are logged in owner_billing_events, and
-- the team gets an email with the reason so we can help.
-- ============================================================

-- Synchronous web calls from Postgres. If the extension cannot be
-- created here the rest still applies; the billing calls then report
-- "not connected" and the account falls back to our own records.
do $$
begin
  create extension if not exists http with schema extensions;
exception when others then
  raise notice 'http extension not available: %', sqlerrm;
end $$;

create table if not exists public.owner_billing_events (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid references public.venues(id) on delete set null,
  owner_email text,
  action      text not null,          -- cancel / resume / portal
  reason      text,
  detail      text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_owner_billing_events_venue
  on public.owner_billing_events(venue_id, created_at desc);
alter table public.owner_billing_events enable row level security;
drop policy if exists "owner_billing_events admin" on public.owner_billing_events;
create policy "owner_billing_events admin" on public.owner_billing_events
  for select to authenticated using (public.is_admin());

-- One call to Stripe. Returns the parsed JSON, or {"error": ...}.
create or replace function public.stripe_call(p_method text, p_path text, p_form text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  key  text;
  st   integer;
  ct   text;
  body jsonb;
begin
  select decrypted_secret into key
    from vault.decrypted_secrets where name = 'stripe_billing_key' limit 1;
  if coalesce(key, '') = '' then
    return jsonb_build_object('error', 'not_connected');
  end if;
  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '9000');
  exception when others then null; end;
  -- Types named only inside the query, so this function can be created
  -- even where the http extension is missing (it then says so).
  select r.status, r.content into st, ct from extensions.http((
    upper(p_method),
    'https://api.stripe.com/v1/' || p_path,
    array[extensions.http_header('Authorization', 'Bearer ' || key),
          extensions.http_header('Stripe-Version', '2024-06-20')],
    'application/x-www-form-urlencoded',
    p_form)::extensions.http_request) r;
  begin
    body := ct::jsonb;
  exception when others then
    body := jsonb_build_object('error', 'bad_response');
  end;
  if st >= 400 then
    return jsonb_build_object('error', coalesce(body #>> '{error,message}', 'stripe_' || st));
  end if;
  return body;
exception when others then
  return jsonb_build_object('error', 'not_connected', 'detail', left(sqlerrm, 200));
end $$;
revoke all on function public.stripe_call(text, text, text) from public, anon, authenticated;

-- The space, if this person may see its billing: its owner, or a
-- founder (read only, for previews).
create or replace function public.billing_venue(p_venue uuid, p_write boolean)
returns public.venues language plpgsql stable security definer set search_path = public as $$
declare
  v  public.venues%rowtype;
  em text := public.owner_email();
begin
  select * into v from public.venues where id = p_venue;
  if not found then raise exception 'Space not found.'; end if;
  if em is not null and lower(coalesce(v.listing_owner_email, '')) = em then
    return v;
  end if;
  if not p_write and public.is_admin() then
    return v;
  end if;
  raise exception 'This space is not in your Owner account.';
end $$;
revoke all on function public.billing_venue(uuid, boolean) from public, anon, authenticated;

-- Everything the Plan & billing tab shows.
create or replace function public.owner_billing(p_venue uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v    public.venues%rowtype;
  sub  jsonb;
  cus  jsonb;
  inv  jsonb;
  pm   jsonb;
  subs jsonb;
  sid  text;
  cid  text;
  base jsonb;
begin
  v := public.billing_venue(p_venue, false);
  base := jsonb_build_object(
    'tier', coalesce(v.listing_tier, 'free'),
    'paid_at', v.listing_paid_at,
    'renews_at', v.listing_renews_at,
    'has_stripe', v.stripe_customer_id is not null);
  cid := v.stripe_customer_id;
  if cid is null then
    return base || jsonb_build_object('connected', false, 'reason', 'no_customer');
  end if;

  sid := v.stripe_subscription_id;
  if sid is null then
    subs := public.stripe_call('GET', 'subscriptions?status=all&limit=1&customer=' || cid);
    if subs ? 'error' then
      return base || jsonb_build_object('connected', false, 'reason', subs->>'error');
    end if;
    sid := subs #>> '{data,0,id}';
  end if;

  if sid is not null then
    sub := public.stripe_call('GET', 'subscriptions/' || sid ||
                              '?expand[]=default_payment_method');
    if sub ? 'error' then
      return base || jsonb_build_object('connected', false, 'reason', sub->>'error');
    end if;
  end if;
  cus := public.stripe_call('GET', 'customers/' || cid ||
                            '?expand[]=invoice_settings.default_payment_method');
  inv := public.stripe_call('GET', 'invoices?limit=24&customer=' || cid);
  if cus ? 'error' then
    return base || jsonb_build_object('connected', false, 'reason', cus->>'error');
  end if;

  pm := coalesce(nullif(sub->'default_payment_method', 'null'::jsonb),
                 nullif(cus #> '{invoice_settings,default_payment_method}', 'null'::jsonb));

  return base || jsonb_build_object(
    'connected', true,
    'subscription', case when sub is null then null else jsonb_build_object(
        'status', sub->>'status',
        'cancel_at_period_end', coalesce((sub->>'cancel_at_period_end')::boolean, false),
        'current_period_end', to_timestamp((sub->>'current_period_end')::bigint),
        'amount', (sub #>> '{items,data,0,price,unit_amount}')::bigint,
        'currency', upper(coalesce(sub #>> '{items,data,0,price,currency}', 'eur')),
        'interval', sub #>> '{items,data,0,price,recurring,interval}') end,
    'card', case when pm is null or jsonb_typeof(pm) <> 'object' then null else jsonb_build_object(
        'brand', pm #>> '{card,brand}',
        'last4', pm #>> '{card,last4}',
        'exp_month', pm #>> '{card,exp_month}',
        'exp_year', pm #>> '{card,exp_year}',
        'type', pm->>'type') end,
    'email', cus->>'email',
    'name', cus->>'name',
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object(
        'number', i->>'number',
        'date', to_timestamp((i->>'created')::bigint),
        'amount', coalesce((i->>'amount_paid')::bigint, (i->>'total')::bigint),
        'currency', upper(i->>'currency'),
        'status', i->>'status',
        'view', i->>'hosted_invoice_url',
        'pdf', i->>'invoice_pdf')), '[]'::jsonb)
      from jsonb_array_elements(coalesce(inv->'data', '[]'::jsonb)) i
      where i->>'status' in ('paid', 'open', 'uncollectible')));
end $$;
grant execute on function public.owner_billing(uuid) to authenticated;

-- Cancel renewal (Verified until the end of the paid year) or undo it.
create or replace function public.owner_billing_action(p_venue uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v   public.venues%rowtype;
  em  text := public.owner_email();
  sid text;
  res jsonb;
  subs jsonb;
  until_ text;
begin
  v := public.billing_venue(p_venue, true);
  if p_action not in ('cancel', 'resume') then
    raise exception 'Unknown action.';
  end if;
  sid := v.stripe_subscription_id;
  if sid is null and v.stripe_customer_id is not null then
    subs := public.stripe_call('GET', 'subscriptions?status=active&limit=1&customer=' || v.stripe_customer_id);
    sid := subs #>> '{data,0,id}';
  end if;
  if sid is null then
    raise exception 'We could not find a subscription for this space.';
  end if;
  res := public.stripe_call('POST', 'subscriptions/' || sid,
           'cancel_at_period_end=' || case when p_action = 'cancel' then 'true' else 'false' end);
  if res ? 'error' then
    raise exception 'Stripe did not accept that: %', res->>'error';
  end if;

  insert into public.owner_billing_events (venue_id, owner_email, action, reason)
  values (p_venue, em, p_action, nullif(left(trim(coalesce(p_reason, '')), 1000), ''));

  until_ := to_char(to_timestamp((res->>'current_period_end')::bigint), 'FMDD Mon YYYY');
  -- Tell the team, so someone can help (never blocks the change).
  begin
    perform public.send_owner_email(
      'hello@nomadwise.io',
      v.name || case when p_action = 'cancel' then ': Verified renewal cancelled'
                     else ': Verified renewal back on' end,
      v.name || ' (' || coalesce(v.city, '') || ') '
        || case when p_action = 'cancel'
                then 'cancelled their Verified renewal. They stay Verified until ' || until_ || '.'
                else 'switched their Verified renewal back on.' end
        || E'\n\nOwner: ' || coalesce(em, '?')
        || case when coalesce(p_reason, '') <> '' then E'\nReason: ' || p_reason else '' end,
      'billing_' || p_action, p_venue::text, null, null);
  exception when others then null; end;

  return jsonb_build_object(
    'cancel_at_period_end', coalesce((res->>'cancel_at_period_end')::boolean, false),
    'current_period_end', to_timestamp((res->>'current_period_end')::bigint));
end $$;
grant execute on function public.owner_billing_action(uuid, text, text) to authenticated;

-- A one-off link to Stripe's secure billing page for this owner,
-- opened at the right step: 'card' (update the card), 'details'
-- (billing name, address, tax id) or 'home' (everything).
create or replace function public.owner_billing_portal(p_venue uuid, p_flow text default 'home')
returns text language plpgsql security definer set search_path = public as $$
declare
  v    public.venues%rowtype;
  form text;
  res  jsonb;
begin
  v := public.billing_venue(p_venue, true);
  if v.stripe_customer_id is null then
    raise exception 'There is no billing account for this space yet.';
  end if;
  form := 'customer=' || v.stripe_customer_id
       || '&return_url=' || 'https%3A%2F%2Fnomadmaps.io%2F%3Fowner%26billing';
  if p_flow = 'card' then
    form := form || '&flow_data[type]=payment_method_update';
  end if;
  res := public.stripe_call('POST', 'billing_portal/sessions', form);
  if res ? 'error' then
    raise exception 'Stripe did not open the billing page: %', res->>'error';
  end if;
  insert into public.owner_billing_events (venue_id, owner_email, action, detail)
  values (p_venue, public.owner_email(), 'portal', p_flow);
  return res->>'url';
end $$;
grant execute on function public.owner_billing_portal(uuid, text) to authenticated;
