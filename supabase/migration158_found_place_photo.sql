-- Migration 158: a picture for a shared place nobody has screened yet.
--
-- A shared space's link shows its own name and picture (migration 157's
-- upload, scripts/share_pages.py). A listed space has its page's
-- photos; a place nobody has screened had none stored, so its preview
-- showed the app icon (Jonathan, 7 Oct 2026: "can the image be an
-- image of the listing"). The app already makes a plain link for the
-- first photo when somebody opens such a place's card (one Google
-- call, paid for the card itself). That link is now kept here, at no
-- further cost, and the next build puts it on the place's share page.
--
--   discovered_places.photo_url     the link, a Google image address
--   discovered_places.photo_url_at  when it was kept
--   discovered_photo(place, url)    what the app calls; only a Google
--                                   image address is accepted, and a
--                                   kept link is replaced only once it
--                                   is three weeks old (the links can
--                                   stop working with time)

alter table public.discovered_places
  add column if not exists photo_url text,
  add column if not exists photo_url_at timestamptz;

create or replace function public.discovered_photo(p_place text, p_url text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_place is null or p_url is null
     or char_length(p_url) > 600
     or p_url !~ '^https://[a-z0-9-]+\.googleusercontent\.com/[A-Za-z0-9_=./-]+$' then
    return;
  end if;
  update public.discovered_places d
     set photo_url = p_url,
         photo_url_at = now()
   where d.google_place_id = p_place
     and (d.photo_url is null
          or d.photo_url_at is null
          or d.photo_url_at < now() - interval '21 days');
end $$;

revoke all on function public.discovered_photo(text, text) from public;
grant execute on function public.discovered_photo(text, text)
  to anon, authenticated, service_role;
