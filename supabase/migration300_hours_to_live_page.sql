-- ============================================================
-- Migration 300: new opening hours reach a live page by themselves
-- ============================================================
-- Jonathan, 9 Nov 2026: "I can't see the updated opening hours are
-- live on the site yet" (The Capsule). The hours were saved on the
-- space, but nothing told the website push to write them: a page that
-- is already live only gets a listing sync when a plan or an owner's
-- change asks for one, and that sync wrote hours only from owner
-- content. Now changing a live space's hours asks for a listing sync,
-- and the sync writes the space's own hours (scripts/webflow_sync.py,
-- owner_fields). The page has them within minutes.
-- ============================================================

create or replace function public.venue_hours_to_page()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.webflow_cms_id is not null
     and new.opening_hours is not null
     and new.opening_hours is distinct from old.opening_hours then
    new.listing_sync_requested_at := now();
    new.listing_synced_at := null;
    new.listing_sync_error := null;
  end if;
  return new;
end $$;

drop trigger if exists venue_hours_to_page on public.venues;
create trigger venue_hours_to_page
  before update of opening_hours on public.venues
  for each row execute function public.venue_hours_to_page();
