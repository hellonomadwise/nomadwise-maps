-- Other spaces near a listing page, for "Also in <area>" under the page.
--
-- Jonathan, 26 Nov 2026 (listing page redesign, combined version):
-- today a listing page is a dead end; a visitor this space does not
-- suit leaves the site. The page now shows up to four spaces close by,
-- with their rating, how far away they are and their lowest price.
--
-- page_nearby(slug) returns up to four released listings of the same
-- kind (coworking or cafe) within 5 km, nearest first, never the space
-- itself and never another branch of the same brand (the part of the
-- name before " - ", so a Fora page does not list other Foras). For
-- each, its live priced products when its own page shows prices, so
-- every price shown is one its own page also shows. Distance is in a
-- straight line. Public, read only, like page_prices. Safe to run twice.
create or replace function public.page_nearby(p_slug text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  slug_ text := lower(btrim(coalesce(p_slug, '')));
  v     record;
  cfg   jsonb;
  out_  jsonb;
begin
  if slug_ = '' or length(slug_) > 200 then
    return '[]'::jsonb;
  end if;

  select x.id, x.name, x.type, x.lat, x.lng into v
    from public.venues x
   where lower(x.webflow_slug) = slug_
   limit 1;
  if v.id is null or v.lat is null or v.lng is null then
    return '[]'::jsonb;
  end if;

  select value into cfg from public.sync_settings where key = 'price_cards';

  with near as (
    select x.id, x.name, x.webflow_slug, x.google_rating_snapshot, x.google_reviews_snapshot,
           round((6371000 * acos(least(1.0,
             cos(radians(v.lat)) * cos(radians(x.lat)) * cos(radians(x.lng) - radians(v.lng))
             + sin(radians(v.lat)) * sin(radians(x.lat)))))::numeric) as metres
      from public.venues x
     where x.id <> v.id
       and x.website_status = 'released'
       and x.website_retired_at is null
       and coalesce(x.business_status, 'OPERATIONAL') = 'OPERATIONAL'
       and coalesce(x.type, '') = coalesce(v.type, '')
       and x.webflow_slug is not null
       and x.lat is not null and x.lng is not null
       and abs(x.lat - v.lat) < 0.06
       and abs(x.lng - v.lng) < 0.1
       and lower(btrim(split_part(x.name, ' - ', 1))) <> lower(btrim(split_part(v.name, ' - ', 1)))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', n.name,
           'slug', n.webflow_slug,
           'rating', n.google_rating_snapshot,
           'reviews', n.google_reviews_snapshot,
           'metres', n.metres,
           'prices', case
             when coalesce((cfg ->> 'on')::boolean, false)
                  or coalesce(cfg -> 'slugs', '[]'::jsonb) ? lower(n.webflow_slug)
             then (select coalesce(jsonb_agg(jsonb_build_object(
                            'name', p.name,
                            'category', coalesce(nullif(p.category, ''), 'coworking'),
                            'amount', p.amount,
                            'currency', p.currency,
                            'label', p.price_label,
                            'details', coalesce(p.details, '[]'::jsonb))
                            order by p.amount), '[]'::jsonb)
                     from (select * from public.venue_products q
                            where q.venue_id = n.id and q.status = 'live' and q.amount is not null
                            order by q.amount limit 12) p)
             else '[]'::jsonb end)
           order by n.metres), '[]'::jsonb)
    into out_
    from (select * from near where metres <= 5000 order by metres limit 4) n;

  return out_;
end
$function$;

revoke all on function public.page_nearby(text) from public;
grant execute on function public.page_nearby(text) to anon, authenticated, service_role;
