-- ============================================================
-- Migration 135: the Owner account opens with the page as it is.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026, looking at a free claim's Owner account
-- (PLACE Coworking Phuket): the page preview said "No photos yet"
-- although the page has photos, the opening hours all read "Not set"
-- although the page shows Google's, and the description box was empty
-- although the page has a description. An owner who sees their real
-- page is more likely to work on it.
--
-- The Owner account (owner_venues) and the founders' preview of it
-- (admin_owner_view) now also carry:
--   page_photos       the photo links on the page today, in page order
--                     (from the nightly read, venue_page_facts);
--   google_hours      the weekly hours Google shows, written the way
--                     the page writes them, for when the owner has set
--                     none of their own;
--   page_description  the page's own text even before the first copy
--                     for a new owner has run;
--   page_products     the passes and prices the page shows (name and
--                     price as written), to look at; changing them
--                     from the Owner account comes later.
-- Nothing is written anywhere: these are reads.
-- ============================================================

-- Google's weekly hours as {"mon": "9:00 AM - 5:00 PM", ...}, in the
-- house style the website push uses (plain hyphen, a space either
-- side). Google leaves out the first AM or PM when both times share
-- it ("1:00 - 5:00 PM"); it is put back so the form can show the day
-- in its two time boxes.
create or replace function public.owner_google_hours(g jsonb)
returns jsonb language plpgsql immutable as $$
declare
  descs jsonb := g -> 'regularOpeningHours' -> 'weekdayDescriptions';
  keys  text[] := array['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  names text[] := array['monday', 'tuesday', 'wednesday', 'thursday',
                        'friday', 'saturday', 'sunday'];
  line  text;
  n     bigint;
  k     text;
  t     text;
  out   jsonb := '{}'::jsonb;
begin
  if descs is null or jsonb_typeof(descs) <> 'array' then
    return out;
  end if;
  for line, n in
    select x, ord from jsonb_array_elements_text(descs) with ordinality as e(x, ord)
     order by ord
  loop
    if position(':' in line) = 0 then
      continue;
    end if;
    -- By the day's name when it is in English, else by its place
    -- (Google lists Monday first).
    k := keys[array_position(names, lower(btrim(split_part(line, ':', 1))))];
    if k is null and n between 1 and 7 then
      k := keys[n];
    end if;
    if k is null or out ? k then
      continue;
    end if;
    t := substr(line, position(':' in line) + 1);
    t := regexp_replace(t, '[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]', '-', 'g');
    t := regexp_replace(t, '[\u00a0\u2009\u202f\u2007]', ' ', 'g');
    t := regexp_replace(t, '\s*-\s*', ' - ', 'g');
    t := btrim(regexp_replace(t, '\s{2,}', ' ', 'g'));
    t := regexp_replace(t, '^(\d{1,2}:\d{2}) - (\d{1,2}:\d{2}) ([AaPp][Mm])$',
                        '\1 \3 - \2 \3');
    if t <> '' then
      out := out || jsonb_build_object(k, t);
    end if;
  end loop;
  return out;
end $$;
revoke all on function public.owner_google_hours(jsonb) from public, anon, authenticated;

-- What the page shows today, beyond the columns the Owner account
-- already reads. Called only from the two functions below.
create or replace function public.owner_page_extras(v public.venues)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'page_photos', coalesce(
      (select jsonb_agg(u order by ord)
         from public.venue_page_facts f,
              jsonb_array_elements_text(
                case when jsonb_typeof(f.facts -> 'photo_urls') = 'array'
                     then f.facts -> 'photo_urls' else '[]'::jsonb end)
                with ordinality as e(u, ord)
        where f.venue_id = v.id and u ~* '^https?://'),
      '[]'::jsonb),
    'page_description', coalesce(
      nullif(btrim(v.page_description), ''),
      (select nullif(btrim(f.facts ->> 'desc'), '')
         from public.venue_page_facts f where f.venue_id = v.id)),
    'google_hours', public.owner_google_hours(v.g_details),
    'page_products', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'name', p.name,
                'label', coalesce(nullif(btrim(p.price_label), ''),
                                  public.product_label(p.amount, p.currency)),
                'category', p.category)
              order by p.position, p.name)
         from public.venue_products p
        where p.venue_id = v.id and p.status = 'live'),
      '[]'::jsonb))
$$;
revoke all on function public.owner_page_extras(public.venues) from public, anon, authenticated;

-- The same as migration 96, with the page as it is added.
create or replace function public.owner_venues()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em  text := public.owner_email();
  out jsonb;
begin
  if em is null then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', v.id,
      'name', v.name,
      'type', v.type,
      'city', v.city,
      'neighbourhood', v.neighbourhood,
      'country', v.country,
      'webflow_slug', v.webflow_slug,
      'website_status', v.website_status,
      'listing_tier', v.listing_tier,
      'listing_paid_at', v.listing_paid_at,
      'listing_renews_at', v.listing_renews_at,
      'listing_enquiry_email', v.listing_enquiry_email,
      'website', v.website,
      'instagram', v.instagram,
      'opening_hours', v.opening_hours,
      'wifi_speed_mbps', v.wifi_speed_mbps,
      'google_rating_snapshot', v.google_rating_snapshot,
      'google_reviews_snapshot', v.google_reviews_snapshot,
      'facts', jsonb_build_object(
        'laptops_allowed', v.laptops_allowed,
        'power_outlets', v.power_outlets,
        'aircon', v.aircon,
        'comfortable_seating', v.comfortable_seating,
        'cozy', v.cozy,
        'quiet_space', v.quiet_space,
        'good_for_calls', v.good_for_calls,
        'call_room', v.call_room,
        'monitor', v.monitor,
        'office_chairs', v.office_chairs,
        'access_24h', v.access_24h),
      'google_photos', (select coalesce(jsonb_agg(value), '[]'::jsonb)
                          from jsonb_each_text(coalesce(v.google_photo_urls, '{}'::jsonb))),
      'page_description', v.page_description,
      'owner_content', v.owner_content,
      'owner_content_at', v.owner_content_at,
      'draft', (select jsonb_build_object(
                  'id', d.id, 'draft', d.draft, 'status', d.status,
                  'submitted_at', d.submitted_at, 'reviewed_at', d.reviewed_at,
                  'review_note', d.review_note, 'updated_at', d.updated_at)
                  from public.owner_drafts d
                 where d.venue_id = v.id
                 order by d.updated_at desc limit 1)
    ) || public.owner_page_extras(v) order by v.name), '[]'::jsonb)
    into out
    from public.venues v
   where lower(v.listing_owner_email) = em;
  return out;
end $$;
grant execute on function public.owner_venues() to authenticated;

-- The same as migration 105, with the page as it is added.
create or replace function public.admin_owner_view(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select jsonb_build_object(
      'id', v.id,
      'name', v.name,
      'type', v.type,
      'city', v.city,
      'neighbourhood', v.neighbourhood,
      'country', v.country,
      'webflow_slug', v.webflow_slug,
      'website_status', v.website_status,
      'listing_tier', v.listing_tier,
      'listing_paid_at', v.listing_paid_at,
      'listing_renews_at', v.listing_renews_at,
      'listing_enquiry_email', v.listing_enquiry_email,
      'listing_owner_email', v.listing_owner_email,
      'claim_email', (select c.owner_email from public.listing_claims c
                       where c.venue_id = v.id
                         and c.status not in ('abandoned', 'rejected')
                       order by c.created_at desc limit 1),
      'website', v.website,
      'instagram', v.instagram,
      'opening_hours', v.opening_hours,
      'wifi_speed_mbps', v.wifi_speed_mbps,
      'google_rating_snapshot', v.google_rating_snapshot,
      'google_reviews_snapshot', v.google_reviews_snapshot,
      'facts', jsonb_build_object(
        'laptops_allowed', v.laptops_allowed,
        'power_outlets', v.power_outlets,
        'aircon', v.aircon,
        'comfortable_seating', v.comfortable_seating,
        'cozy', v.cozy,
        'quiet_space', v.quiet_space,
        'good_for_calls', v.good_for_calls,
        'call_room', v.call_room,
        'monitor', v.monitor,
        'office_chairs', v.office_chairs,
        'access_24h', v.access_24h),
      'google_photos', (select coalesce(jsonb_agg(value), '[]'::jsonb)
                          from jsonb_each_text(coalesce(v.google_photo_urls, '{}'::jsonb))),
      'page_description', v.page_description,
      'owner_content', v.owner_content,
      'owner_content_at', v.owner_content_at,
      'draft', (select jsonb_build_object(
                  'id', d.id, 'draft', d.draft, 'status', d.status,
                  'submitted_at', d.submitted_at, 'reviewed_at', d.reviewed_at,
                  'review_note', d.review_note, 'updated_at', d.updated_at)
                  from public.owner_drafts d
                 where d.venue_id = v.id
                 order by d.updated_at desc limit 1))
      || public.owner_page_extras(v)
    into out
    from public.venues v
   where v.id::text = p_key or v.webflow_slug = p_key
   limit 1;
  return out;
end $$;
revoke all on function public.admin_owner_view(text) from public;
grant execute on function public.admin_owner_view(text) to authenticated;
