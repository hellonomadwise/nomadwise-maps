-- ============================================================
-- Migration 105: the founder preview shows the owner's own email.
-- (Applied automatically by the build; nothing to paste.)
--
-- In a founder's preview of a claimed-but-not-checked Owner account,
-- "We email you at ..." showed the founder's address (Leonie, S3-2/3).
-- admin_owner_view now also returns the listing's owner email and the
-- latest claim's email, and the preview uses those. Otherwise the
-- same as migration 98.
-- ============================================================

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
      -- Who the owner is (or who claimed it), so the preview shows their
      -- address, not the founder's, in "We email you at ..." (S3-2/3).
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
    into out
    from public.venues v
   where v.id::text = p_key or v.webflow_slug = p_key
   limit 1;
  return out;
end $$;
revoke all on function public.admin_owner_view(text) from public;
grant execute on function public.admin_owner_view(text) to authenticated;
