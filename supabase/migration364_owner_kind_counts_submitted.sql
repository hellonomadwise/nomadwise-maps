-- ============================================================
-- Migration 364: an owner who sent a change is Hands-on
-- (Owen's read, 26 Nov 2026). Stone Soup sent a change on 24 Nov
-- with no edit_save step on record, only "submitted", and was still
-- tagged Looker and still offered "Short on time?". Both now count
-- a "submitted" step as a saved change (migration 355 counted
-- edit_save only).
-- ============================================================
select public.pm_patch_fn('public.admin_owner_activity(integer,boolean)',
  $a$x.owner_email = o.em and x.kind = 'edit_save')$a$,
  $a$x.owner_email = o.em and x.kind in ('edit_save', 'submitted'))$a$,
  $a$x.kind in ('edit_save', 'submitted')$a$);
select public.pm_patch_fn('public.owner_track(uuid,jsonb,jsonb)',
  $a$a.owner_email = em and a.kind = 'edit_save')$a$,
  $a$a.owner_email = em and a.kind in ('edit_save', 'submitted'))$a$,
  $a$a.kind in ('edit_save', 'submitted')$a$);
