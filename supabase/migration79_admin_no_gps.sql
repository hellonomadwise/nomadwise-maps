-- ============================================================
-- Migration 79: founders may submit a review without a GPS fix.
-- (Applied automatically by the build; nothing to paste.)
--
-- The review form asks the browser where the nomad is, so a
-- submission carries proof they were at the space. On a laptop
-- Chrome usually says no, which stopped Jonathan adding a cafe from
-- his desk. Nomads still need the fix; a founder's submission may
-- have none; the reviewer then sees no distance on the card.
-- ============================================================

alter table public.submissions alter column gps_lat drop not null;
alter table public.submissions alter column gps_lng drop not null;
