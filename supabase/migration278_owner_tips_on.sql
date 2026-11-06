-- ============================================================
-- Migration 278: owner tips switched on.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: "Ok" to the four test tips (27 to 30, with
-- Unsubscribe in the grey footer). The daily run (09:47 UTC) starts
-- recording each page's checklist from tomorrow; nothing is sent from
-- the 1st to the 10th of the month, so the first tips go on 11 Nov.
-- To switch off again:
--   update public.sync_settings set value = '{"on": false}' where key = 'owner_tips';
-- ============================================================

update public.email_templates set live = true where alias like 'tip-%' and not live;
update public.sync_settings set value = '{"on": true}'::jsonb where key = 'owner_tips';
