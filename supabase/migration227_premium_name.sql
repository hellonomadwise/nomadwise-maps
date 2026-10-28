-- ============================================================
-- Migration 227: the paid plan is called Premium, not Plus.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 28 Oct 2026: "lets update everything to premium" (the
-- research is in listings/2026-10-28-paid-plan-name.md). A naming
-- change only: who gets which email, and when, is unchanged.
--   * every database function whose text says "Plus" (the owner
--     emails, the red email button "See Nomadwise Premium", the claim
--     page message, plan ended, page live, held enquiries, the site
--     chat's description of the plans, the founders' notices) is
--     re-created from its live version with "Plus" swapped for
--     "Premium" and nothing else changed
--   * the Outreach templates, the same swap
-- Only the capitalised word Plus is swapped, so the "plus" key the
-- app reads (owner_enquiry_allowance) and "the plus sign" stay.
-- Emails already sent are history and are left as they were.
-- The badge stays "Verified by Nomadwise"; the plan's key in the
-- data stays 'verified'.
-- Pure ASCII. Safe to apply twice: a second run finds nothing to swap.
-- ============================================================

do $$
declare
  r record;
begin
  for r in
    select p.oid, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and p.prosrc ~ '\mPlus\M'
  loop
    execute regexp_replace(pg_get_functiondef(r.oid), '\mPlus\M', 'Premium', 'g');
    raise notice 'Premium: re-created %', r.proname;
  end loop;
end $$;

update public.outreach_templates
   set body = regexp_replace(body, '\mPlus\M', 'Premium', 'g')
 where body ~ '\mPlus\M';
