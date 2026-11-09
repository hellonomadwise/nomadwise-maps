-- ============================================================
-- Migration 290: exchange rates, to show prices in euros too
-- ============================================================
-- Jonathan, 9 Nov 2026, on prices an owner sent in Tanzanian
-- shillings: "how would I know otherwise, if in local currency ...
-- could we add in for review, if in local currency, how much
-- equivalent that would mean in euros?". Price check now shows
-- "about EUR 3.70" beside a price in another currency.
--
-- fx_rates: how many of each currency make one euro, refreshed about
-- once a day by scripts/fx_rates.py (the ten-minute workflow; it
-- exits at once when the rates are less than a day old). Rates from
-- ExchangeRate-API's free daily rates (open.er-api.com), which cover
-- every currency we list in, Tanzanian shillings included. Only for
-- the team to judge a price: no price on nomadwise.io is converted.
-- ============================================================

create table if not exists public.fx_rates (
  currency    text primary key,             -- ISO code, e.g. TZS
  per_eur     numeric not null check (per_eur > 0),  -- units for one euro
  updated_at  timestamptz not null default now()
);

alter table public.fx_rates enable row level security;

drop policy if exists fx_rates_admin_read on public.fx_rates;
create policy fx_rates_admin_read on public.fx_rates
  for select to authenticated using (public.is_admin());

grant select on public.fx_rates to authenticated;
