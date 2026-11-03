-- ============================================================
-- Migration 243: price cards on the listing pages (the feed).
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 3 Nov 2026 (mockup approved): a listing page on
-- nomadwise.io shows the space's prices as cards, one per group
-- (Coworking, Private offices, Meeting rooms, Other). The visitor picks
-- one price, says how many people and when (a calendar), and sends one
-- enquiry, which goes through the page's existing enquiry form, so it
-- reaches Nomad Maps as every enquiry does (free pages: 2 to the space,
-- then held for Premium).
--
-- The page script (nomadmaps.io/prices.js) asks this, by the page's
-- address, for the prices on the page (venue_products, live ones only).
--
-- Switch: sync_settings 'price_cards' = {"on": false, "slugs": [...]}.
-- With "on" false the cards show only on the pages listed in "slugs"
-- (OUR HQ first); with "on" true on every listing page with prices.
-- Read-only, public (the prices are on the page anyway). Pure ASCII.
-- Safe to apply twice.
-- ============================================================

insert into public.sync_settings (key, value)
values ('price_cards', jsonb_build_object(
          'on', false,
          'slugs', jsonb_build_array('scotland-glasgow-our-hq')))
on conflict (key) do nothing;

create or replace function public.page_prices(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  cfg   jsonb;
  slug_ text := lower(btrim(coalesce(p_slug, '')));
  v     record;
  items jsonb;
begin
  if slug_ = '' or length(slug_) > 200 then
    return jsonb_build_object('show', false);
  end if;
  select value into cfg from public.sync_settings where key = 'price_cards';
  if not coalesce((cfg ->> 'on')::boolean, false)
     and not coalesce(cfg -> 'slugs', '[]'::jsonb) ? slug_ then
    return jsonb_build_object('show', false);
  end if;

  select x.id, x.name into v
    from public.venues x
   where lower(x.webflow_slug) = slug_
   limit 1;
  if v.id is null then
    return jsonb_build_object('show', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'name', p.name,
           'category', coalesce(nullif(p.category, ''), 'coworking'),
           'amount', p.amount,
           'currency', p.currency,
           'label', p.price_label,
           'from', coalesce(p.starting_from, false),
           'vat_included', p.vat_included,
           'details', coalesce(p.details, '[]'::jsonb))
           order by p.position, p.created_at), '[]'::jsonb)
    into items
    from public.venue_products p
   where p.venue_id = v.id and p.status = 'live';

  return jsonb_build_object(
    'show', jsonb_array_length(items) > 0,
    'space', v.name,
    'prices', items);
end $$;
revoke all on function public.page_prices(text) from public;
grant execute on function public.page_prices(text) to anon, authenticated;
