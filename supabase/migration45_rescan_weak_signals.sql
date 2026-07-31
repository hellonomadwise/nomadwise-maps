-- ============================================================
-- Migration 45 — recheck weakly-promoted places.
-- (Applied automatically by the build; nothing to paste.)
--
-- The signal scanner learnt new negative phrasings ("only thing
-- missing was wifi..." previously counted as a POSITIVE wifi
-- mention and promoted the pin). Places whose promotion rests on
-- only one or two mentions are sent back to the scanner queue so
-- the new rules can confirm or correct them. Their signals stay
-- as they are until each rescan lands, then update in place.
-- ============================================================

update public.discovered_places
   set signals_checked_at = null
 where coalesce(signal_negative, 0) = 0
   and coalesce(signal_wifi, 0) + coalesce(signal_power, 0)
       + coalesce(signal_laptop, 0) between 1 and 2;
