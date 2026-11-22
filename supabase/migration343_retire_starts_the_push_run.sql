-- "Retire the page" starts the website push run at once, for every page
-- (Jonathan, 22 Nov 2026, after KoHub's retire sat for seventeen minutes
-- with nothing happening: "ok lets do that :)").
--
-- nudge_website_sync() only woke the run for a venue that was queued or
-- had been approved in the app. 949 of the 1,042 live pages came from
-- Webflow and were never approved in the app, so for them a retire
-- request waited for GitHub's schedule (hours in practice). A retire
-- request now passes that gate and the one-minute throttle, as an
-- approval or Publish does.
--
-- Three small patches, each safe to run again (pm_patch_fn says
-- 'already' when its marker is there).
select public.pm_patch_fn('public.nudge_website_sync()',
  '  publish_asked boolean;',
  E'  publish_asked boolean;\n  retire_asked boolean := false;',
  'retire_asked boolean');
select public.pm_patch_fn('public.nudge_website_sync()',
  '  if not (new.website_status = ''queued'' or new.website_approved_at is not null) then',
  E'  -- Retire pressed (migration 343): starts the run for every page, also\n  -- the ones that came from Webflow and were never approved in the app.\n  retire_asked := tg_op = ''UPDATE''\n              and new.website_retire_requested_at is not null\n              and old.website_retire_requested_at is null;\n  if not (new.website_status = ''queued'' or new.website_approved_at is not null\n          or retire_asked) then',
  'or retire_asked) then');
select public.pm_patch_fn('public.nudge_website_sync()',
  '  if not (approval or publish_asked) and last_nudge is not null',
  '  if not (approval or publish_asked or retire_asked) and last_nudge is not null',
  'publish_asked or retire_asked');
