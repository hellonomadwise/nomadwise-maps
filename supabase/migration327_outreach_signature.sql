-- ============================================================
-- Migration 327: the Outreach hello ends with the same signature
-- as every other email.
--
-- Jonathan, 12 Nov 2026, on the first-contact hello in Outreach:
-- "With the Kind regards and the Jonathan Heavens it should be per
-- our email signature". The agreed one (6 Nov, migration 265):
-- "Kind regards," / Jonathan Heavens in bold / "Co-founder,
-- nomadwise.io" with nomadwise.io in Nomadwise red.
--
-- "Send from here" (outreach_plain_html) drew its own older version
-- (migration 183): a thin line above the name, and "Co-founder .
-- Nomadwise.io" with a dot and a capital N. Now: no line, a comma,
-- lower-case nomadwise.io, and the same space under "Kind regards,".
-- The words in the template were already right; nothing changes in
-- the text version or in what "My own inbox" pastes.
--
-- Applied through the connector the same day; each patch skips
-- itself when it is already in. Pure ASCII. Safe to apply twice.
-- ============================================================

select public.pm_patch_fn('public.outreach_plain_html(text)',
  $a$'margin:0;font-size:15px;line-height:1.6;color:#1F2933;">Kind regards,</p>'$a$,
  $a$'margin:8px 0 10px 0;font-size:15px;line-height:1.6;color:#142032;">Kind regards,</p>'$a$,
  $a$margin:8px 0 10px 0;font-size:15px$a$);

select public.pm_patch_fn('public.outreach_plain_html(text)',
  $a$style="margin:14px 0 0 0;border-collapse:collapse;">'$a$,
  $a$style="margin:0;border-collapse:collapse;">'$a$,
  $a$style="margin:0;border-collapse:collapse;">'$a$);

select public.pm_patch_fn('public.outreach_plain_html(text)',
  $a$'padding:12px 0 0 0;border-top:1px solid #E6E9ED;">'$a$,
  $a$'padding:0;">'$a$,
  $a$'padding:0;">'$a$);

select public.pm_patch_fn('public.outreach_plain_html(text)',
  $a$Co-founder &middot; '$a$,
  $a$Co-founder, '$a$,
  $a$Co-founder, '$a$);

select public.pm_patch_fn('public.outreach_plain_html(text)',
  $a$text-decoration:none;">Nomadwise.io</a>'$a$,
  $a$text-decoration:none;">nomadwise.io</a>'$a$,
  $a$text-decoration:none;">nomadwise.io</a>'$a$);
