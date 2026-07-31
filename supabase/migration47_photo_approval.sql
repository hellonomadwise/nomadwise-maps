-- ============================================================
-- Migration 47 — community photos wait for founder approval.
-- (Applied automatically by the build; nothing to paste.)
--
-- Reviews can auto-verify on the GPS check, which until now ALSO
-- published their photo instantly. Facts and photos carry different
-- risks: a wrong "has plugs" is annoying, a bad photo (poor quality,
-- someone's face, something inappropriate) is a trust problem. So a
-- photo now has its own status and only shows on the space page
-- after an admin approves it. Photos already public stay public.
-- ============================================================

alter table public.submissions
  add column if not exists photo_status text not null default 'pending';

-- Photos that were already live keep their place.
update public.submissions
   set photo_status = 'approved'
 where photo_path is not null
   and status = 'verified';

create or replace view public.venue_photos as
  select venue_id, photo_path, verified_at
    from public.submissions
   where status = 'verified'
     and venue_id is not null
     and photo_path is not null
     and photo_status = 'approved';

grant select on public.venue_photos to anon, authenticated;

-- A ping when a new photo lands, so approval never waits long.
create or replace function public.notify_photo_pending()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.photo_path is not null then
    perform public.notify_phone(
      'Nomadmaps photo to review',
      'A new community photo is waiting for approval in admin',
      'key');
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists trg_notify_photo_pending on public.submissions;
create trigger trg_notify_photo_pending
  after insert on public.submissions
  for each row execute function public.notify_photo_pending();
