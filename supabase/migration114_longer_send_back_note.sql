-- ============================================================
-- Migration 114: room for a fuller Send back note.
-- (Applied automatically by the build; nothing to paste.)
--
-- Send back now suggests replies worked out from what the owner
-- entered, and "Use all" puts several in one note. A note was capped at
-- 1,000 characters and anything longer was cut off without a word; the
-- cap is now 2,500, the same as the box in the control centre.
-- ============================================================

do $$
declare c record;
begin
  for c in
    select con.conname from pg_constraint con
     where con.conrelid = 'public.owner_drafts'::regclass
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%review_note%'
  loop
    execute format('alter table public.owner_drafts drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.owner_drafts
  add constraint owner_drafts_review_note_check
  check (char_length(review_note) <= 2500);

create or replace function public.owner_decline_draft(p_draft uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  update public.owner_drafts
     set status = 'declined',
         reviewed_at = now(),
         updated_at = now(),
         review_note = nullif(left(trim(coalesce(p_note, '')), 2500), '')
   where id = p_draft and status = 'submitted';
  if not found then
    raise exception 'This draft is not waiting for review.';
  end if;
end $$;
grant execute on function public.owner_decline_draft(uuid, text) to authenticated;
