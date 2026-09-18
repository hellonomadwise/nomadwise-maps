-- ============================================================
-- Migration 59: plain links for each venue's Google photos.
-- (Applied automatically by the build; nothing to paste.)
--
-- Showing a Google photo through Google's media endpoint is billed
-- every time it loads. Resolving a photo once to its plain image
-- link (lh3.googleusercontent.com) and keeping that link on the
-- venue makes every later view free: the map cards, the space page,
-- the review form and the website photo suggestions all use it.
--
--   venues.google_photo_urls   { "<photo name>": "<plain link>", ... }
--
-- Filled by the nightly job (a capped number per night, so the
-- backlog costs a little over a few weeks rather than at once) and
-- by the app the first time a nomad opens a place's reference
-- photos. cache_google_photos merges, never overwrites, and any
-- signed-in nomad may call it: a link is not sensitive.
-- ============================================================

alter table public.venues
  add column if not exists google_photo_urls jsonb;

create or replace function public.cache_google_photos(p_venue uuid, p_urls jsonb)
returns void language sql security definer set search_path = public as $$
  update public.venues
     set google_photo_urls = coalesce(google_photo_urls, '{}'::jsonb) || coalesce(p_urls, '{}'::jsonb)
   where id = p_venue
     and auth.uid() is not null
     and jsonb_typeof(coalesce(p_urls, '{}'::jsonb)) = 'object';
$$;

revoke all on function public.cache_google_photos(uuid, jsonb) from public;
grant execute on function public.cache_google_photos(uuid, jsonb) to authenticated;
