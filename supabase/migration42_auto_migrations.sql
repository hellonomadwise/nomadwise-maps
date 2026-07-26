-- ============================================================
-- Migration 42 — the LAST migration you paste by hand.
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- (works fine from a phone browser too)
--
-- Installs a migration runner inside the database: a function that
-- only the server key (kept in GitHub's secret store, never in the
-- app) is allowed to call. From now on the build pipeline applies
-- new migration files automatically on every push and records each
-- one, so nothing ever runs twice and nothing needs pasting again.
-- ============================================================

-- 1. The ledger of applied migrations.
create table if not exists public.schema_migrations (
  name       text primary key,
  applied_at timestamptz not null default now()
);
alter table public.schema_migrations enable row level security;
-- no policies: only the service role (which bypasses RLS) touches it

-- 2. The runner. SECURITY DEFINER so it may run DDL; locked to the
-- service role, which only exists in GitHub Actions secrets.
create or replace function public.apply_migration(p_name text, p_sql text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'not allowed';
  end if;
  if exists (select 1 from public.schema_migrations where name = p_name) then
    return 'already applied';
  end if;
  execute p_sql;
  insert into public.schema_migrations (name) values (p_name);
  return 'applied';
end $$;

revoke all on function public.apply_migration(text, text)
  from public, anon, authenticated;

-- 3. Baseline: every migration up to and including this one is
-- already in the database by hand; record them so the runner never
-- re-runs them.
insert into public.schema_migrations (name) values
  ('migration2_verification.sql'),
  ('migration3_photos_freshness.sql'),
  ('migration4_discovery.sql'),
  ('migration5_optional_photo.sql'),
  ('migration6_wifi_test.sql'),
  ('migration7_wifi_logins.sql'),
  ('migration8_coworking_fields.sql'),
  ('migration9_leaderboard.sql'),
  ('migration10_city_fix.sql'),
  ('migration11_avatars.sql'),
  ('migration12_admin_users.sql'),
  ('migration13_activity_detail.sql'),
  ('migration14_coin_release_fix.sql'),
  ('migration15_network_fingerprint.sql'),
  ('migration16_discovery_bonus.sql'),
  ('migration16b_repair_and_bonus.sql'),
  ('migration17_euro_balance.sql'),
  ('migration18_feedback.sql'),
  ('migration19_app_events.sql'),
  ('migration20_admin_economy.sql'),
  ('migration21_cohorts.sql'),
  ('migration22_economy_by_group.sql'),
  ('migration23_venue_credits.sql'),
  ('migration24_google_cache.sql'),
  ('migration25_phone_notifications.sql'),
  ('migration26_team_devices.sql'),
  ('migration27_visit_summaries.sql'),
  ('migration28_bot_gate.sql'),
  ('migration29_nomad_signals.sql'),
  ('migration30_named_pings.sql'),
  ('migration31_leaderboard_no_team.sql'),
  ('migration32_datacenter_gate.sql'),
  ('migration33_vpn_rescue.sql'),
  ('migration34_city_sweeps.sql'),
  ('migration35_coworking_cleanup.sql'),
  ('migration36_photo_curation.sql'),
  ('migration37_webflow_import.sql'),
  ('migration38_serves_food.sql'),
  ('migration39_activity_privacy.sql'),
  ('migration40_wifi_public.sql'),
  ('migration41_no_passwords.sql'),
  ('migration42_auto_migrations.sql')
on conflict (name) do nothing;
