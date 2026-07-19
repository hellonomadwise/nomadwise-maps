-- ============================================================
-- Nomadwise Maps — migration 19: in-app analytics for the admin
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- The app mirrors its analytics events here so the admin can see
-- who has looked around (signed in or not) and what they did,
-- right inside the app. Only the admin can read it.
-- ============================================================

create table if not exists public.app_events (
  id         uuid primary key default gen_random_uuid(),
  anon_id    text not null,          -- per-device visitor id
  user_id    uuid references auth.users(id),  -- set once signed in
  name       text not null,
  props      jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_app_events_time
  on public.app_events (created_at desc);
create index if not exists idx_app_events_anon
  on public.app_events (anon_id);

alter table public.app_events enable row level security;

drop policy if exists "anyone logs events" on public.app_events;
create policy "anyone logs events" on public.app_events
  for insert with check (true);

drop policy if exists "admin reads events" on public.app_events;
create policy "admin reads events" on public.app_events
  for select using (public.is_admin());
