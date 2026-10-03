-- ============================================================
-- Migration 118: "from €4 a month" before a country is known.
-- (Applied automatically by the build; nothing to paste.)
--
-- pricing_for('') falls back to group B, so the claim form's overview
-- (step 1, before a space is picked) read "€10 a month, or €99 a year"
-- as if that were the one price. Now the answer also carries the
-- cheapest Verified price across all groups, in euro cents:
--   from_monthly_eur, from_yearly_eur
-- The app shows "from €4 a month" when the country is not mapped, and
-- the real price once a space (and so a country) is chosen. Everything
-- else in pricing_for() is as in migration 115.
-- ============================================================

create or replace function public.pricing_for(p_country text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_iso text := public.pricing_country_iso(p_country);
  c    public.pricing_countries%rowtype;
  g    public.pricing_groups%rowtype;
  curs text[] := '{}';
  cur  text;
  mon  jsonb := '{}'::jsonb;
  yr   jsonb := '{}'::jsonb;
  a_m  integer;
  a_y  integer;
  ready boolean;
  from_m integer;
  from_y integer;
begin
  if v_iso is not null then
    select * into c from public.pricing_countries pc where pc.iso = v_iso;
  end if;
  if v_iso is null or c.iso is null then
    -- Unknown country: group B in euros, until a founder maps it.
    select * into g from public.pricing_groups where code = 'B';
    c.iso := null; c.name := null; c.group_code := 'B'; c.currency := 'EUR'; c.currency_locked := false;
  else
    select * into g from public.pricing_groups where code = c.group_code;
  end if;

  -- The currencies on offer: the country's own first, then the others
  -- Stripe has amounts for. Locked (the UK) means only its own.
  foreach cur in array (case when c.currency_locked then array[c.currency]
                             else array[c.currency, 'USD', 'EUR', 'GBP'] end) loop
    if cur = any(curs) then continue; end if;
    a_m := public.pricing_amount(g, 'monthly', cur);
    a_y := public.pricing_amount(g, 'yearly', cur);
    if a_m is null or a_y is null then continue; end if;
    curs := curs || cur;
    mon := mon || jsonb_build_object(cur, a_m);
    yr  := yr  || jsonb_build_object(cur, a_y);
  end loop;
  if array_length(curs, 1) is null then
    curs := array['EUR'];
    mon := jsonb_build_object('EUR', public.pricing_amount(g, 'monthly', 'EUR'));
    yr  := jsonb_build_object('EUR', public.pricing_amount(g, 'yearly', 'EUR'));
  end if;

  -- The cheapest Verified price anywhere, for "from €4 a month".
  select round(min(monthly_eur) * 100)::integer, round(min(yearly_eur) * 100)::integer
    into from_m, from_y
    from public.pricing_groups;

  ready := coalesce(g.stripe_price_monthly, '') <> '' and coalesce(g.stripe_price_yearly, '') <> '';
  return jsonb_build_object(
    'iso', c.iso,
    'country', c.name,
    'group', g.code,
    'group_name', g.name,
    'currency', curs[1],
    'currencies', to_jsonb(curs),
    'locked', coalesce(c.currency_locked, false),
    'monthly', mon,
    'yearly', yr,
    'monthly_eur', g.monthly_eur,
    'yearly_eur', g.yearly_eur,
    'from_monthly_eur', from_m,
    'from_yearly_eur', from_y,
    'ready', ready,
    'mapped', c.iso is not null);
end $$;
grant execute on function public.pricing_for(text) to anon, authenticated, service_role;
