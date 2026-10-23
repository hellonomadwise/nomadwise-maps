-- ============================================================
-- Migration 209: the "Did you find a place?" email, one line changed.
--
-- Jonathan, 23 Oct 2026: the line "If you are still looking, reply to
-- this email and I will help you find somewhere." becomes "If you have
-- any questions, simply reply to this email." (it promised more than
-- we want to offer). Everything else as migration 203. The daily send
-- and the preview in Enquiries both use this function, so both change.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.enquiry_followup_text(p_first text, p_names text[])
returns text language sql immutable set search_path = public as $$
  select 'Hi ' || coalesce(nullif(btrim(coalesce(p_first, '')), ''), 'there') || ',' || E'\n\n'
      || 'A few days ago you asked ' || public.enquiry_space_names(p_names)
      || ' on nomadwise.io about working there. Did you find a place?' || E'\n\n'
      || 'It takes one tap to tell us. It helps us know which spaces reply, so we '
      || 'can point other remote workers the right way.' || E'\n\n'
      || 'If you have any questions, simply reply to this email.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise';
$$;
revoke all on function public.enquiry_followup_text(text, text[]) from public, anon, authenticated;

notify pgrst, 'reload schema';
