-- ============================================================
-- Migration 96: the Owner account starts from the page's own words.
-- (Applied automatically by the build; nothing to paste.)
--
-- The description box used to open empty, and whatever the owner
-- wrote replaced our longer description (Leonie's review, 28 Sep).
-- The website push now copies each owned page's description (Best
-- Text) into venues.page_description, and the Owner account opens
-- with it in the box, to edit rather than replace. Left unchanged, the
-- page keeps its own formatting.
-- ============================================================

alter table public.venues
  add column if not exists page_description text,
  add column if not exists page_text_at timestamptz;

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
    ) order by v.name), '[]'::jsonb)
    into out
    from public.venues v
   where lower(v.listing_owner_email) = em;
  return out;
end $$;
grant execute on function public.owner_venues() to authenticated;
