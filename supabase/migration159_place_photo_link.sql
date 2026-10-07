-- Migration 159: the picture of a shared place, looked up at the
-- moment the link is shown.
--
-- A shared place's small page is made at build time
-- (scripts/share_pages.py), so a picture kept after the last build
-- (migration 158) did not reach the preview until the next upload:
-- Jonathan shared IDEA Spaces minutes after opening it and still got
-- the app icon (7 Oct 2026). The page of a place nobody has screened
-- now points its picture at this function instead of at a fixed link.
-- Asked for a place, it answers "the picture is over there" (a
-- redirect) with the photo link the app kept, at a size that suits a
-- preview, or with the app icon when there is none. So the photo
-- shows from the first share, as long as the sharer has opened the
-- place's card, which is where the Share button is.
--
-- It only ever points at a Google image address held in
-- discovered_places, or at our own icon: it cannot be used to send
-- anyone anywhere else.

create or replace function public.place_photo(p text)
returns void
language plpgsql stable security definer set search_path = public as $$
declare
  u text;
begin
  select d.photo_url into u
    from public.discovered_places d
   where d.google_place_id = p
     and d.photo_url ~ '^https://[a-z0-9-]+\.googleusercontent\.com/[A-Za-z0-9_=./-]+$';
  if u is null then
    u := 'https://nomadmaps.io/icons/og_square.png';
  else
    -- Google's image links carry their size after the last "=".
    u := regexp_replace(u, '=[^=/]*$', '=s1200');
  end if;
  perform set_config('response.status', '302', true);
  perform set_config('response.headers',
    json_build_array(
      json_build_object('Location', u),
      json_build_object('Cache-Control', 'public, max-age=600'))::text,
    true);
end $$;

revoke all on function public.place_photo(text) from public;
grant execute on function public.place_photo(text)
  to anon, authenticated, service_role;
