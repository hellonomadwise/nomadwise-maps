-- ============================================================
-- Migration 238: the nomadwise.io website chat points to spaces@ too.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 3 Nov 2026: the website chat goes on spaces@ as well.
-- Its emails already go through send_owner_email, so since migration
-- 237 they come from "Nomadwise Spaces <spaces@nomadwise.io>". This
-- changes the last two places it says hello@: the "busy" messages in
-- site_chat_send. Patched where it stands. Pure ASCII. Safe to apply
-- twice.
-- ============================================================

do $do$
declare
  r record;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public' and p.proname = 'site_chat_send'
       and p.prosrc like '%hello@nomadwise.io%'
  loop
    execute replace(pg_get_functiondef(r.oid), 'hello@nomadwise.io', 'spaces@nomadwise.io');
  end loop;
end
$do$;
