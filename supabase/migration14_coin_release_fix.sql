-- ============================================================
-- Nomadwise Maps — migration 14: release stuck coins
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- Bug: on a new submission, triggers fire in ALPHABETICAL order.
-- "trg_auto_verify" ran before "trg_award_coins", so GPS-verified
-- submissions got their coins created AFTER the release step had
-- already come and gone: coins stuck on 'pending' forever.
-- Fix: rename so awarding runs first, and release everything stuck.
-- ============================================================

-- 1. Re-order: a_ awards first, b_ verifies second.
drop trigger if exists trg_award_coins on public.submissions;
drop trigger if exists trg_auto_verify on public.submissions;

create trigger trg_a_award_coins
  after insert on public.submissions
  for each row execute function public.award_coins_on_submission();

create trigger trg_b_auto_verify
  after insert on public.submissions
  for each row execute function public.auto_verify_confirm();

-- 2. Backfill: any pending coins whose submission is already verified
--    become withdrawable now.
update public.coin_ledger l
   set status = 'withdrawable'
  from public.submissions s
 where s.id = l.submission_id
   and s.status = 'verified'
   and l.status = 'pending';
