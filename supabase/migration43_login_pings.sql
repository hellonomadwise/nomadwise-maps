-- ============================================================
-- Migration 43 — named ping when someone logs in.
-- (Applied automatically by the build; nothing to paste.)
--
-- "Visitor 155900 opened the app" followed by silence hid the most
-- interesting moment: that visitor deciding to sign in. Now the
-- moment of login sends its own ping with the person's name, so the
-- story reads: visitor arrives -> Virginia logged in.
-- Deduped per user per 6 hours; team accounts stay silent.
-- ============================================================

create or replace function public.notify_signed_in()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  who text;
begin
  if new.name = 'signed_in'
     and new.user_id is not null
     and not public.is_team_member(new.user_id)
     and not exists (
       select 1 from public.app_events e
        where e.name = 'signed_in'
          and e.user_id = new.user_id
          and e.id <> new.id
          and e.created_at > now() - interval '6 hours')
  then
    select nullif(display_name, '') into who
      from public.profiles where id = new.user_id;
    perform public.notify_phone(
      'Someone is on Nomadmaps',
      coalesce(who, 'A nomad') || ' logged in',
      'key');
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists trg_notify_signed_in on public.app_events;
create trigger trg_notify_signed_in
  after insert on public.app_events
  for each row execute function public.notify_signed_in();
