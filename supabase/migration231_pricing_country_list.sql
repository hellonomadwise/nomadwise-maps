-- ============================================================
-- Migration 231: the countries for the pricing page.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 30 Oct 2026: a pricing page anyone can open
-- (nomadmaps.io/pricing). It asks "Where is your space?" first and
-- shows the Premium price for that country, from pricing_for()
-- (migration 115) as the claim page does. This lists the countries
-- with a price, A to Z, for its dropdown: names and codes only, the
-- same facts pricing_for() already gives anyone.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.pricing_country_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('iso', pc.iso, 'name', pc.name)
                            order by pc.name), '[]'::jsonb)
    from public.pricing_countries pc
   where coalesce(pc.name, '') <> '' and pc.group_code is not null;
$$;
revoke all on function public.pricing_country_list() from public;
grant execute on function public.pricing_country_list() to anon, authenticated;
