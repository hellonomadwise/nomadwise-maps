-- ============================================================
-- Migration 88: photo links made when someone looks, for everyone.
-- (Applied automatically by the build; nothing to paste.)
--
-- The nightly refresh used to pay Google for a plain link to six
-- photos of every space every three weeks, whether or not anyone
-- opened the space. It no longer does. Instead the app makes a
-- photo's link the first time a visitor sees it and saves it on the
-- venue here, so every later visitor gets it free.
--
-- Until now only signed-in nomads could save links. Most visitors
-- are not signed in, so any visitor may now, with checks: the photo
-- name must belong to this venue's Google place, the link must be a
-- Google image link, and at most twelve at a time. Links are merged,
-- never removed; the nightly refresh clears them with the old names.
-- ============================================================

create or replace function public.cache_google_photos(p_venue uuid, p_urls jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  pid text;
  prefix text;
  clean jsonb := '{}'::jsonb;
  k text;
  v text;
begin
  if jsonb_typeof(coalesce(p_urls, 'null'::jsonb)) <> 'object' then
    return;
  end if;
  select google_place_id into pid from public.venues where id = p_venue;
  if pid is null then return; end if;
  prefix := 'places/' || pid || '/photos/';
  for k, v in select key, value from jsonb_each_text(p_urls) limit 12 loop
    if left(k, length(prefix)) = prefix
       and v ~ '^https://[a-z0-9.-]+\.googleusercontent\.com/' then
      clean := clean || jsonb_build_object(k, v);
    end if;
  end loop;
  if clean = '{}'::jsonb then return; end if;
  update public.venues
     set google_photo_urls = coalesce(google_photo_urls, '{}'::jsonb) || clean
   where id = p_venue;
end $$;

revoke all on function public.cache_google_photos(uuid, jsonb) from public;
grant execute on function public.cache_google_photos(uuid, jsonb) to anon, authenticated;
