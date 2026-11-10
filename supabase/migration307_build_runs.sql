-- ============================================================
-- Migration 307: every build says how it ended
-- ============================================================
-- Jonathan, 10 Nov 2026: "if you can spot failures that would be
-- great". Claude can send changes to GitHub (migration 306) but cannot
-- see GitHub's Actions page. The build workflow's last job
-- (scripts/report_build.py) now writes one row per run here: whether
-- the build and the deploy passed, and on a failure which step failed
-- and the end of its log, so the failure can be read and fixed from
-- the chat. A failed build also pings the founders' phones.
-- ============================================================

create table if not exists public.build_runs (
  run_id      bigint primary key,
  run_number  integer,
  attempt     integer not null default 1,
  sha         text,
  event       text,
  result      text not null,   -- success | failure | cancelled
  build       text,            -- the build job's result
  deploy      text,            -- the deploy job's result
  failed      text,            -- "job > step" of what failed
  log_tail    text,            -- the end of the failed job's log
  run_url     text,
  finished_at timestamptz not null default now()
);

create index if not exists build_runs_sha on public.build_runs (sha);

alter table public.build_runs enable row level security;
revoke all on table public.build_runs from public, anon, authenticated;

notify pgrst, 'reload schema';
