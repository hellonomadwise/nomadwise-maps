-- ============================================================
-- Nomadwise Maps — migration 36: photo curation
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- Each venue remembers which Google photos are hidden (the bagel
-- close-ups). Admins hide/unhide instantly from the photo
-- carousel; reviewers can deselect photos in the review form and
-- their choices apply when the submission is verified.
-- ============================================================

alter table public.venues
  add column if not exists hidden_photos text[] not null default '{}';

-- Apply a verified reviewer's photo deselections to the venue.
create or replace function public.apply_photo_prefs()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  bad text[];
begin
  if new.status = 'verified' and old.status is distinct from 'verified'
     and new.venue_id is not null
     and jsonb_typeof(coalesce(new.payload->'hidden_photos',
                               'null'::jsonb)) = 'array' then
    select coalesce(array_agg(x), '{}') into bad
      from jsonb_array_elements_text(new.payload->'hidden_photos') t(x);
    if coalesce(array_length(bad, 1), 0) > 0 then
      update public.venues
         set hidden_photos = (
           select array(select distinct
                        unnest(coalesce(hidden_photos, '{}') || bad)))
       where id = new.venue_id;
    end if;
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists trg_c_apply_photo_prefs on public.submissions;
create trigger trg_c_apply_photo_prefs
  after update on public.submissions
  for each row execute function public.apply_photo_prefs();
