-- ============================================================
-- Migration 87: keep food photos out of the default Google photos.
-- (Applied automatically by the build; nothing to paste.)
--
-- When a space has no photos chosen for its nomadwise.io page, the
-- app shows Google's photos, and those are often plates of food.
-- The nightly job now looks at each of them once, with the same
-- food rule the website photo suggestions use, and lists the food
-- and drink close-ups here; the app leaves them out (and shows them
-- only if a space has nothing else at all).
--
--   venues.food_photos     Google photo names judged to be food
--   venues.photos_checked  Google photo names already looked at
--
-- Both are keyed by the same photo names as google_photo_urls and
-- are trimmed to the current names at each refresh. A founder who
-- taps "show this photo again" on a space page removes the name
-- from food_photos; it stays in photos_checked, so the job does not
-- flag it again.
-- ============================================================

alter table public.venues
  add column if not exists food_photos text[] not null default '{}',
  add column if not exists photos_checked text[] not null default '{}';
