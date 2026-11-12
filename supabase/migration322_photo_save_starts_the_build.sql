-- ============================================================
-- Migration 322: saving the missing photo starts the build
-- ============================================================
-- Jonathan, 12 Nov 2026, on SwissOffices Yapı Kredi Plaza: approved
-- the evening before, held for a third photo. The photo was added at
-- 05:06 and the page was still not built twenty minutes later.
--
-- Why: the website run is started by the database (nudge_website_sync,
-- migration 57); GitHub's own ten-minute schedule in practice comes
-- round every few hours. That trigger leaves out "the sync's own
-- writes": an update that changes website_prepared while the status
-- and the approval stay as they were. Saving photos in the control
-- centre is exactly such an update (Add photos writes the photo list
-- and, in the same save, takes "needs one more photo" off
-- website_prepared), so the save that unblocks a page started nothing
-- and the page waited for the schedule.
--
-- Now a save that changes the photo list is never taken for the sync's
-- own write (the sync does not write website_photos).
-- ============================================================

select public.pm_patch_fn('public.nudge_website_sync()',
$a$     and old.website_status = new.website_status$a$,
$a$     and old.website_status = new.website_status
     -- a photo list saved with it is the founder's save (migration 322)
     and old.website_photos is not distinct from new.website_photos$a$,
$m$migration 322$m$);
