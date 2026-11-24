-- Migration 356: a page we claimed ourselves as a test is not counted
-- as claimed in the Claim plan (Jonathan, 24 Nov 2026, asked whether
-- Instant Crunch Saldanha, owned by his own address, should be left out
-- of the Claimed numbers: "ok fine, lay any stats out how you think is
-- best").
--
-- admin_claim_plan() sends "test" with each claimed page: true when the
-- space has Outreach lines and every one of them is marked as a test.
-- The screen still counts the page as a space, not as a claim. Nothing
-- else the function returns changes.

select public.pm_patch_fn('public.admin_claim_plan()',
  $a$'wrote_first', exists ($a$,
  $a$'test', (exists (select 1 from public.space_contacts t where t.venue_id = v.id)
                                  and not exists (select 1 from public.space_contacts t
                                                   where t.venue_id = v.id
                                                     and not coalesce(t.is_test, false))),
                         'wrote_first', exists ($a$,
  $a$'test', (exists$a$);
