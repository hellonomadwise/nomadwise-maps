-- ============================================================
-- Migration 274: the Emails view knows when opens and clicks began.
-- (Applied automatically by the build; nothing to paste.)
--
-- Postmark started recording opens and clicks on our emails on
-- 5 Nov 2026 at 21:25 UTC (when they moved to the templates). An email
-- sent before then has no opens or clicks to find, so it counts as
-- "not known" rather than "not opened"; the view works out open and
-- click rates only from the emails sent since.
-- ============================================================

select public.pm_patch_fn('public.admin_email_flow(date)',
  $a$s.message_id is not null as tracked$a$,
  $a$(s.message_id is not null and s.sent_at >= timestamptz '2026-11-05 21:25:00+00') as tracked$a$,
  $m$timestamptz '2026-11-05 21:25:00+00'$m$);
