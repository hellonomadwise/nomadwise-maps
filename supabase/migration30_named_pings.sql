-- ============================================================
-- Nomadwise Maps — migration 30: names in arrival pings
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- When a signed-in user opens the app, the phone ping now shows
-- their name instead of "Visitor xxxxxx ... (signed in)".
-- ============================================================

create or replace function public.notify_app_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  who text;
begin
  if new.name = 'app_opened'
     and not public.looks_like_bot(new.props->>'ua')
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
    if new.user_id is not null then
      select nullif(display_name, '') into who
        from public.profiles where id = new.user_id;
    end if;
    perform public.notify_phone(
      'Someone is on Nomadmaps',
      coalesce(who, 'Visitor ' || right(new.anon_id, 6))
        || ' opened the app',
      'eyes');
  end if;
  return new;
exception when others then
  return new;
end $$;
