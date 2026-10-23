-- ============================================================
-- Migration 215: switch on 2 free enquiries for claimed free pages.
-- (Applied automatically by the build; nothing to paste.)
--
-- CR-31. Leonie said yes to the two emails (migration 214), 23 Oct,
-- and Jonathan asked for it to go on. From now on:
--   * a claimed free page's first 2 enquiries in total go straight to
--     the space, and the nomad is told;
--   * after that, the owner is told one is waiting and that Nomadwise
--     Plus brings unlimited enquiries; the enquiry shows to the
--     founders under "Held for Plus", with "Move to pass on";
--   * going on Plus sends everything held;
--   * pages nobody has claimed still wait to be passed on by hand.
-- Counting starts now: spaces claimed earlier start at 0.
-- To switch off again, in the SQL editor:
--   update public.sync_settings
--      set value = jsonb_build_object('on', false, 'limit', 2)
--    where key = 'free_enquiries';
-- Pure ASCII. Safe to apply twice.
-- ============================================================

insert into public.sync_settings (key, value)
values ('free_enquiries', jsonb_build_object('on', true, 'limit', 2))
on conflict (key) do update
  set value = jsonb_build_object('on', true, 'limit', 2);

notify pgrst, 'reload schema';
