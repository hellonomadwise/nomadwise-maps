-- ============================================================
-- Migration 103: after "Send back", see only what the owner changed.
-- (Applied automatically by the build; nothing to paste.)
--
-- When an owner submits again after we sent their changes back, the
-- Owner changes card now also gets:
--   sent_back.note      the note we sent them
--   sent_back.at        when we sent it
--   sent_back.previous  what they had submitted before that note
-- so the card can show "What they changed since your note", field by
-- field and word by word, instead of the whole submission again.
-- A sent-back draft is never edited (the owner's next save starts a
-- new draft), so this works for sends-back from before today too.
-- Everything else the function returns is unchanged.
-- ============================================================

create or replace function public.owner_drafts_to_review()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id,
      'venue_id', d.venue_id,
      'owner_email', d.owner_email,
      'draft', d.draft,
      'status', d.status,
      'submitted_at', d.submitted_at,
      'sent_back', (
        -- A sent-back draft is kept as it was (the owner's next save
        -- starts a new one), so it holds both our note and what they
        -- had submitted.
        select jsonb_build_object(
                 'note', x.review_note,
                 'at', x.reviewed_at,
                 'previous', x.draft)
          from public.owner_drafts x
         where x.venue_id = d.venue_id
           and x.id <> d.id
           and x.status = 'declined'
           and x.reviewed_at is not null
           and x.reviewed_at <= coalesce(d.submitted_at, now())
           -- only this round: not a note from before changes were put on
           and not exists (select 1 from public.owner_drafts a
                            where a.venue_id = d.venue_id
                              and a.status = 'applied'
                              and a.reviewed_at > x.reviewed_at)
         order by x.reviewed_at desc limit 1),
      'venue', jsonb_build_object(
        'name', v.name, 'city', v.city, 'country', v.country,
        'type', v.type, 'webflow_slug', v.webflow_slug,
        'listing_tier', v.listing_tier, 'website', v.website,
        'instagram', v.instagram, 'opening_hours', v.opening_hours,
        'owner_content', v.owner_content,
        'facts', jsonb_build_object(
          'laptops_allowed', v.laptops_allowed,
          'power_outlets', v.power_outlets, 'aircon', v.aircon,
          'comfortable_seating', v.comfortable_seating, 'cozy', v.cozy,
          'quiet_space', v.quiet_space, 'good_for_calls', v.good_for_calls,
          'call_room', v.call_room, 'monitor', v.monitor,
          'office_chairs', v.office_chairs, 'access_24h', v.access_24h))
    ) order by d.submitted_at asc), '[]'::jsonb)
    from public.owner_drafts d
    join public.venues v on v.id = d.venue_id
   where d.status = 'submitted');
end $$;
grant execute on function public.owner_drafts_to_review() to authenticated;
