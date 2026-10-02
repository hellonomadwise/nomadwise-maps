-- ============================================================
-- Migration 116: prices written with their symbol.
-- (Applied automatically by the build; nothing to paste.)
--
-- "€10 a month or €99 a year", never "10 EUR" (Jonathan, 2 Oct): the
-- symbol is how people write money; the code is bank language.
-- ============================================================

create or replace function public.money_sign(p_currency text)
returns text language sql immutable as $$
  select case upper(coalesce(p_currency, ''))
           when 'EUR' then '€' when 'GBP' then '£' when 'USD' then '$'
           when 'AUD' then 'A$' else upper(coalesce(p_currency, '')) || ' ' end;
$$;

create or replace function public.verified_price_words(p_country text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  p   jsonb := public.pricing_for(p_country);
  cur text := p->>'currency';
  m   numeric := (p->'monthly'->>cur)::numeric / 100;
  y   numeric := (p->'yearly'->>cur)::numeric / 100;
begin
  -- Until the prices are in Stripe, today's price, as the app charges.
  if not coalesce((p->>'ready')::boolean, false) then
    return '€99 a year';
  end if;
  return public.money_sign(cur) || public.money_words(m) || ' a month or '
      || public.money_sign(cur) || public.money_words(y) || ' a year';
end $$;
grant execute on function public.verified_price_words(text) to anon, authenticated, service_role;
