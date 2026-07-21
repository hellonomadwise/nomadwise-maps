-- ============================================================
-- Nomadwise Maps — migration 35: fix mislabelled coworking spaces
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- Google pads sparse "coworking" searches with loosely related
-- venues (restaurants, department stores) and these got labelled
-- as coworking spaces (The Delaunay, Sketch, Selfridges...).
-- Demote any "coworking" entry whose Google type never said so
-- and whose name does not say so either. They stay on the map
-- as ordinary unscreened places.
-- ============================================================

update public.discovered_places
   set primary_type = null
 where primary_type = 'coworking_space'
   and name !~* '(cowork|co-work|co work|workspace|work ?space|work ?hub|wework)';
