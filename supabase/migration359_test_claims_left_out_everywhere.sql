-- Migration 359: our own test claims are left out of the last two
-- Owners counts that still had no rule for them (Jonathan, 24 Nov 2026,
-- asked whether to leave test claims out of the Owners numbers as in
-- the Claim plan: "yes").
--
-- Most Owners numbers already did this (the Owner flow, Home's claims):
-- a claim is a test when its email is in owner_flow_team_emails or
-- holds "nomadwise", or the owner's name holds "test". On 24 Nov that
-- rule catches all 20 test claims of the 50 on record. Two counts did
-- not use it: "claimed after we wrote, last 30 days" in the Owner flow
-- signals, and "paid" in Analytics. Neither was wrong on the day (5 and
-- 5; the three paid claims, all ours, are from September), but both
-- would have counted the next test. The rule now lives in one place.

create or replace function public.claim_is_test(p_email text, p_name text)
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select lower(coalesce(p_email, '')) in (select lower(t.email) from public.owner_flow_team_emails t)
      or lower(coalesce(p_email, '')) like '%nomadwise%'
      or coalesce(p_name, '') ilike '%test%'
$$;
revoke all on function public.claim_is_test(text, text) from public, anon, authenticated;

select public.pm_patch_fn('public.admin_owner_flow_signals(timestamp with time zone)',
  $a$and lc.created_at <= t and lc.status in ('free', 'paid')$a$,
  $a$and lc.created_at <= t and lc.status in ('free', 'paid')
                             and not public.claim_is_test(lc.owner_email, lc.owner_name)$a$,
  $a$claim_is_test(lc.owner_email$a$);

select public.pm_patch_fn('public.admin_analytics(integer,text,integer)',
  $a$where c.paid_at >= since)$a$,
  $a$where c.paid_at >= since
                                                and not public.claim_is_test(c.owner_email, c.owner_name))$a$,
  $a$c.paid_at >= since
                                                and not$a$);

select public.pm_patch_fn('public.admin_analytics(integer,text,integer)',
  $a$where c.paid_at >= prev and c.paid_at < since)$a$,
  $a$where c.paid_at >= prev and c.paid_at < since
                                                and not public.claim_is_test(c.owner_email, c.owner_name))$a$,
  $a$c.paid_at < since
                                                and not$a$);
