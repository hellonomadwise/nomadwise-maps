-- ============================================================
-- Migration 228: kinder wording for the second sign-in reminder.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 29 Oct 2026: he did not like "This is the last reminder we
-- send." in the second reminder to an owner who has not signed in to
-- their Owner account. It now gives a reason to sign in instead. The
-- subject ("Anything we can help with for <space>?"), the button, the
-- first reminder and who gets which reminder, and when, are unchanged.
-- signin_reminder_text is its live version with only the step 2 body
-- changed.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.signin_reminder_text(
  p_step integer, p_first text, p_space text, p_url text)
returns table(subject text, body text)
language sql immutable
as $function$
  select
    case when p_step = 1
         then 'Your Owner account for ' || p_space || ' is ready'
         else 'Anything we can help with for ' || p_space || '?' end,
    case when p_step = 1 then
           'Hi ' || p_first || ',' || E'\n\n'
           || 'A quick reminder that ' || p_space || ' is yours to manage on Nomadwise.'
           || coalesce(' Your page: ' || nullif(btrim(coalesce(p_url, '')), ''), '') || E'\n\n'
           || 'Your Owner account is here: https://nomadmaps.io/owner' || E'\n'
           || 'Sign in with this email address. There is no password: we send you a sign-in link.'
           || E'\n\n'
           || 'Once you are in, you can update your opening hours and contact details, '
           || 'and add your own photos, description and prices.' || E'\n\n'
           || 'If anything is unclear, just reply to this email.' || E'\n\n'
           || 'Jonathan'
         else
           'Hi ' || p_first || ',' || E'\n\n'
           || 'Just checking in on ' || p_space || '. It looks like you haven''t had a '
           || 'chance to sign in to your Owner account yet. If something got in the way, '
           || 'reply to this email and I will sort it out.' || E'\n\n'
           || 'Once you are in, you can keep your hours, prices and contact details up '
           || 'to date, and add your own photos and description, so nomads see '
           || p_space || ' at its best.' || E'\n\n'
           || 'Jonathan' end;
$function$;
