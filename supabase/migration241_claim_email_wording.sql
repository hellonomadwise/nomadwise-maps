-- ============================================================
-- Migration 241: warmer opening lines in the "claim approved" emails.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 3 Nov 2026: the email a space gets when we approve its
-- claim opened with "Done: we have confirmed you are with ...". That
-- reads like a note to ourselves, not a message to a new owner. Now:
--
--   Free claim approved:
--     "Good news: we've confirmed you're with OUR HQ, so its page on
--      Nomadwise is now yours to manage."
--   Premium claim approved:
--     "Good news: OUR HQ is now on Nomadwise Premium."
--
-- The "page is in our publishing queue" line is split into two easier
-- sentences too. Nothing else in the emails changes.
-- Patched where it stands in claim_emails. Pure ASCII. Safe to apply twice.
-- ============================================================

do $do$
declare
  src text;
  -- Free claim approved: the opening line.
  old_free text := $o$'Done: we have confirmed you are with ' || space || ', and you now manage its '
         || 'page on Nomadwise.'$o$;
  new_free text := $n$'Good news: we''ve confirmed you''re with ' || space || ', so its page on '
         || 'Nomadwise is now yours to manage.'$n$;
  -- Free claim approved: the page is not live yet.
  old_queue text := $o$'The page is in our publishing queue; we check every new page before '
                      || 'it goes live and will email you the link.'$o$;
  new_queue text := $n$'Your page is in our publishing queue. We check every new page before '
                      || 'it goes live, and we''ll email you the link as soon as it is.'$n$;
  -- Premium claim approved: the opening line.
  old_paid text := $o$'Done: ' || space || ' is now on Premium. Your page has the Verified '$o$;
  new_paid text := $n$'Good news: ' || space || ' is now on Nomadwise Premium. Your page has the Verified '$n$;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'claim_emails';
  if src is null or position('''Done: ' in src) = 0 then
    return;  -- not there, or done already
  end if;
  if position(old_free in src) = 0 or position(old_queue in src) = 0
     or position(old_paid in src) = 0 then
    raise exception 'claim_emails is not as expected; wording not changed';
  end if;
  src := replace(src, old_free, new_free);
  src := replace(src, old_queue, new_queue);
  src := replace(src, old_paid, new_paid);
  execute src;
end
$do$;
