-- ============================================================
-- Migration 280: the Emails view shows who unsubscribed.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: "can I know if anyone unsubscribed". For the
-- emails that can be switched off (the monthly email and the owner
-- tips): how many switched them off after getting one, and who (with
-- the stop link in the email or the switch in Settings).
-- ============================================================

select public.pm_patch_fn('public.admin_email_flow(date)',
  $a$(s.message_id is not null and s.sent_at >= timestamptz '2026-11-05 21:25:00+00') as tracked$a$,
  $a$(s.message_id is not null and s.sent_at >= timestamptz '2026-11-05 21:25:00+00') as tracked,
      (select p.updated_at from public.owner_email_prefs p
        where p.email = s.em and p.updated_at >= s.sent_at
          and ((s.kind = 'monthly' and not p.monthly) or (s.kind like 'tip\_%' and not p.tips))) as unsubscribed_at$a$,
  $m$as unsubscribed_at$m$);

select public.pm_patch_fn('public.admin_email_flow(date)',
  $a$count(*) filter (where premium_on is not null) as premium,$a$,
  $a$count(*) filter (where premium_on is not null) as premium,
      count(*) filter (where unsubscribed_at is not null) as unsubscribed,
      bool_or(kind = 'monthly' or kind like 'tip\_%') as can_unsubscribe,$a$,
  $m$as can_unsubscribe$m$);

select public.pm_patch_fn('public.admin_email_flow(date)',
  $a$'tip_done', tip_done, 'premium_on', premium_on$a$,
  $a$'tip_done', tip_done, 'premium_on', premium_on, 'unsubscribed_at', unsubscribed_at$a$,
  $m$'unsubscribed_at', unsubscribed_at$m$);
