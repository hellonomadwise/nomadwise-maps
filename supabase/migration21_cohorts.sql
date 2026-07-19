-- ============================================================
-- Nomadwise Maps — migration 21: account groups for analytics
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- Accounts can be grouped: 'team' (never counted), 'friend'
-- (invited testers), or ungrouped = genuine customers.
-- ============================================================

alter table public.profiles add column if not exists cohort text
  check (cohort in ('team','friend'));

-- The admin may sort accounts into groups.
drop policy if exists "admin updates profiles" on public.profiles;
create policy "admin updates profiles" on public.profiles
  for update using (public.is_admin());

-- Start with the known team accounts.
update public.profiles set cohort = 'team'
 where id in (select id from auth.users where email in (
   'hellonomadwise@gmail.com',
   'leonie.poelking@googlemail.com',
   'jonnythebackpacker@gmail.com',
   'corneliousbeck@gmail.com'));
