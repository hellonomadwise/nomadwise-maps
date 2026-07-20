-- ============================================================
-- Nomadwise Maps — migration 26: remember team devices
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- (Run migration 25 first if you have not yet.)
--
-- Any device that has EVER signed into a team account is
-- remembered here, and from then on it is excluded from the
-- in-app analytics and from phone pings, even when browsing
-- signed out. Devices are recognised by their anonymous id,
-- which browsers keep between visits.
-- ============================================================

create table if not exists public.team_devices (
  anon_id    text primary key,
  first_seen timestamptz not null default now()
);

alter table public.team_devices enable row level security;

drop policy if exists "admin reads team devices" on public.team_devices;
create policy "admin reads team devices" on public.team_devices
  for select using (public.is_admin());

-- (Safety net: defined in migration 21/25; recreated here so this
-- migration works on its own.)
create or replace function public.is_team_member(p_user uuid)
returns boolean language sql stable security definer set search_path = public as
$$ select coalesce(
     (select cohort = 'team' from public.profiles where id = p_user),
     false) $$;

-- Learn team devices as events arrive.
create or replace function public.remember_team_device()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is not null and public.is_team_member(new.user_id) then
    insert into public.team_devices (anon_id) values (new.anon_id)
    on conflict do nothing;
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists trg_a_remember_team_device on public.app_events;
create trigger trg_a_remember_team_device
  after insert on public.app_events
  for each row execute function public.remember_team_device();

-- Learn from history: every device that ever carried a team sign-in.
insert into public.team_devices (anon_id)
select distinct e.anon_id
  from public.app_events e
 where e.user_id is not null
   and public.is_team_member(e.user_id)
on conflict do nothing;

-- Phone pings: stay silent for known team devices too.
create or replace function public.notify_app_open()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.name = 'app_opened'
     and not public.is_team_member(new.user_id)
     and not exists (
       select 1 from public.team_devices td
        where td.anon_id = new.anon_id)
     and not exists (
       select 1 from public.app_events e
        where e.anon_id = new.anon_id
          and e.name = 'app_opened'
          and e.id <> new.id
          and e.created_at > now() - interval '6 hours')
  then
    perform public.notify_phone(
      'Someone is on Nomadmaps',
      'Visitor ' || right(new.anon_id, 6) || ' opened the app'
        || case when new.user_id is not null
                then ' (signed in)' else '' end,
      'eyes');
  end if;
  return new;
exception when others then
  return new;
end $$;
