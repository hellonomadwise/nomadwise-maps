-- ============================================================
-- Migration 303: Publish starts its own fast run
-- ============================================================
-- Jonathan, 10 Nov 2026: Hotel AMANO's draft sat on "Publishing within
-- a minute or two". Publish asked for the general website push, which
-- shares a queue with the hourly Stripe run and the nightly enrichment
-- and carries the photo-scoring step, so it could wait behind them.
-- Now pressing Publish also starts "Website publish" (webflow_publish.yml),
-- a run that only publishes the drafts asked for, in a queue of its
-- own. The general push is still started as before, as the backstop.
-- ============================================================

select public.pm_patch_fn('public.nudge_website_sync()',
$a$  perform net.http_post(
    url := 'https://api.github.com/repos/hellonomadwise/nomadwise-maps'
           '/actions/workflows/webflow_push.yml/dispatches',$a$,
$a$  -- Publish pressed: the fast lane first (migration 303)
  if publish_asked then
    perform net.http_post(
      url := 'https://api.github.com/repos/hellonomadwise/nomadwise-maps'
             '/actions/workflows/webflow_publish.yml/dispatches',
      body := '{"ref":"main"}'::jsonb,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || tok,
        'Accept', 'application/vnd.github+json',
        'Content-Type', 'application/json',
        'User-Agent', 'nomadmaps-db',
        'X-GitHub-Api-Version', '2022-11-28'));
  end if;

  perform net.http_post(
    url := 'https://api.github.com/repos/hellonomadwise/nomadwise-maps'
           '/actions/workflows/webflow_push.yml/dispatches',$a$,
$m$the fast lane first (migration 303)$m$);
