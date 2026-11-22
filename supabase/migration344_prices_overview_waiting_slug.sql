-- Migration 344: Prices overview, the "Most viewed pages not showing
-- prices yet" list carries each page's slug, so the screen can link to
-- the page on nomadwise.io (Jonathan, 22 Nov 2026: "i cant highlight
-- these spaces, make this possible, and a link so I can easily click
-- and open new tab, of space listing url").
--
-- Only admin_prices_dashboard() changes, and only by one more field
-- ('slug') on each row of 'waiting'. Nothing else it returns moves.

select public.pm_patch_fn('public.admin_prices_dashboard()',
  'select l.id, v.name, l.city, l.area, l.country, per.n as products,',
  'select l.id, v.name, v.webflow_slug as slug, l.city, l.area, l.country, per.n as products,',
  'v.webflow_slug as slug, l.city');

select public.pm_patch_fn('public.admin_prices_dashboard()',
  $a$'name', name, 'city', city, 'area', area, 'country', country,$a$,
  $a$'name', name, 'slug', slug, 'city', city, 'area', area, 'country', country,$a$,
  $a$'name', name, 'slug', slug,$a$);
