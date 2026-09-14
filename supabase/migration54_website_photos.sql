-- ============================================================
-- Migration 54: photos chosen for the nomadwise.io page.
-- (Applied automatically by the build; nothing to paste.)
--
-- A listing cannot go to Webflow without pictures. In the control
-- centre the founder pastes up to five image links (the way the
-- listings have always been built: an image from the place's Google
-- page, copied by its address). They are stored here as a list of
-- links, and the sync puts them straight into the Images entry when
-- the draft is created, so nothing is left to do in Webflow but the
-- words. At least three pictures (pasted plus approved community
-- photos) are needed before Approve is offered.
-- ============================================================

alter table public.venues
  add column if not exists website_photos jsonb;
