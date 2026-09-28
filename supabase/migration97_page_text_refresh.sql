-- ============================================================
-- Migration 97: copy the owned pages' descriptions again.
-- (Applied automatically by the build; nothing to paste.)
--
-- The first copy (migration 96) flattened the page's section headings
-- ("Working at ...") into plain lines. The copy now keeps them as
-- "## " lines, which the Owner account shows as headings and the
-- website push turns back into headings. Clearing the copy date makes
-- the next pushes fetch every owned page again (ten per run).
-- ============================================================

update public.venues
   set page_text_at = null
 where listing_owner_email is not null
   and page_text_at is not null;
