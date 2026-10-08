-- 168: no more "... finished a visit" phone notices.
--
-- Jonathan, 8 Oct 2026: "I don't need to receive the ones where it says
-- finished a visit ... not something that when I see it ping up on my
-- phone that is useful to me".
--
-- Those notices came from the job 'summarize-visitors' (migration 27),
-- every 5 minutes. Nothing else uses it, so the job is stopped. The
-- function summarize_quiet_visitors() stays, unused, so it can be
-- switched back on with one line:
--   select cron.schedule('summarize-visitors', '*/5 * * * *',
--     'select public.summarize_quiet_visitors()');
-- Safe to apply twice.

do $$
begin
  perform cron.unschedule('summarize-visitors');
exception when others then null;
end $$;
