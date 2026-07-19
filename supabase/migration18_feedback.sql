-- ============================================================
-- Nomadwise Maps — migration 18: feedback inbox
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- Anyone can send feedback from the menu; only the admin reads it.
-- ============================================================

create table if not exists public.feedback (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users(id),
  message    text not null,
  contact    text,
  status     text not null default 'new'
             check (status in ('new','done')),
  created_at timestamptz not null default now()
);

alter table public.feedback enable row level security;

drop policy if exists "anyone can send feedback" on public.feedback;
create policy "anyone can send feedback" on public.feedback
  for insert with check (true);

drop policy if exists "admin reads feedback" on public.feedback;
create policy "admin reads feedback" on public.feedback
  for select using (public.is_admin());

drop policy if exists "admin updates feedback" on public.feedback;
create policy "admin updates feedback" on public.feedback
  for update using (public.is_admin());
