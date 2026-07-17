-- ============================================================
-- Nomadwise Maps — migration 10: real cities, not default Lisbon
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- ============================================================

-- 1. Stop stamping 'Lisbon' onto every new space
alter table public.venues alter column city drop default;
alter table public.venues alter column city drop not null;

-- 2. User-created spaces that inherited the wrong default get their city
--    cleared; the next build's enrichment job refills them from Google
--    automatically. (Seeded Lisbon spaces are untouched.)
update public.venues
   set city = null
 where created_by is not null
   and city = 'Lisbon';
