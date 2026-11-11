-- ============================================================
-- Migration 315: an enquiry can say "I also need somewhere to stay"
-- ============================================================
-- Jonathan, 11 Nov 2026, on Alessandro's enquiry to Coworking Space
-- H24 (a desk 7 to 13 January, and "do you also have private rooms to
-- stay or any convention with hotels"): "I'm just wanting to consider
-- if there's a way we can systematically accommodate this and build
-- this in. Don't know if it could be part of the coliving plan", and
-- "we will be planning to add lots of coliving spaces".
--
-- Step 1 of the plan (project doc listings/2026-11-11-stay-enquiries-
-- plan.md): count them. A yes/no on the enquiry, ticked by the nomad
-- on the form. Nothing is guessed from the message: a word search for
-- "room" also caught a team asking for private offices.
--
-- * enquiries.wants_stay
-- * the two that asked in their own words this week are marked
-- * the pop-up import reads the tick when the Webflow form has one
--   (payload key "stay")
-- * the control centre's Enquiries list gets the tick and the count
--   over the last 90 days
-- ============================================================

alter table public.enquiries
  add column if not exists wants_stay boolean not null default false;

comment on column public.enquiries.wants_stay is
  'The nomad ticked "I also need somewhere to stay" (migration 315).';

-- Asked in the message before the tick existed.
update public.enquiries
   set wants_stay = true
 where id in ('599f8c37-7333-4a60-97a4-be249e511edf',   -- H24, Koh Phangan, 11 Nov 2026
              'b0f7d4e1-521a-4ea9-8343-eb11a2c46854')   -- SOKKOOL Coliving, 8 Nov 2026
   and not wants_stay;

-- The pop-up import keeps the tick.
select public.pm_patch_fn('public.import_webflow_enquiry(jsonb)',
$a$webflow_submission_id, listing_text, marketing_ok, created_at, handled_note)$a$,
$a$webflow_submission_id, listing_text, marketing_ok, created_at, handled_note, wants_stay)$a$,
$m$handled_note, wants_stay)$m$);

select public.pm_patch_fn('public.import_webflow_enquiry(jsonb)',
$a$case when old then 'From before the pass-on list (Webflow email only).' end)$a$,
$a$case when old then 'From before the pass-on list (Webflow email only).' end,
    lower(coalesce(p->>'stay', '')) in ('true', 'yes', 'on'))$a$,
$m$p->>'stay'$m$);

-- The control centre: the tick on each waiting enquiry, and the count.
select public.pm_patch_fn('public.admin_enquiries_to_pass_on()',
$a$'asked_at', e.asked_at,$a$,
$a$'asked_at', e.asked_at, 'wants_stay', e.wants_stay,$a$,
$m$'wants_stay', e.wants_stay$m$);

select public.pm_patch_fn('public.admin_enquiries_to_pass_on()',
$a$'followup_on', coalesce((select (value ->> 'on')::boolean from public.sync_settings$a$,
$a$'stay_90d', (select count(*) from public.enquiries
                  where wants_stay and created_at > now() - interval '90 days'),
    'all_90d', (select count(*) from public.enquiries
                 where created_at > now() - interval '90 days'),
    'followup_on', coalesce((select (value ->> 'on')::boolean from public.sync_settings$a$,
$m$'stay_90d'$m$);
