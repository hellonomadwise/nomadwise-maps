-- ============================================================
-- Nomadwise Maps — migration 25: phone notifications via ntfy
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- The database pings Jonathan's phone (ntfy app, topic below)
-- the moment interesting things happen:
--   * someone opens the app   (max once per device per 6 hours)
--   * a new submission arrives
--   * someone signs up
--   * feedback lands in the inbox
-- Signed-in team accounts never trigger the first two.
-- A failed notification NEVER blocks the actual action.
-- ============================================================

create extension if not exists pg_net;

-- Where the pings go. To change or silence notifications later,
-- edit or empty this function.
create or replace function public.notify_phone(
  p_title text, p_message text, p_tags text default 'bell')
returns void language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://ntfy.sh',
    body := jsonb_build_object(
      'topic', 'nomadmaps-83076iwunm',
      'title', p_title,
      'message', p_message,
      'tags', string_to_array(p_tags, ',')),
    headers := '{"Content-Type": "application/json"}'::jsonb);
exception when others then
  null; -- notifications are best-effort, never break the app
end $$;

-- True when this user id belongs to a team account.
create or replace function public.is_team_member(p_user uuid)
returns boolean language sql stable security definer set search_path = public as
$$ select coalesce(
     (select cohort = 'team' from public.profiles where id = p_user),
     false) $$;

-- 1. Someone opened the app (once per device per 6 hours).
create or replace function public.notify_app_open()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.name = 'app_opened'
     and not public.is_team_member(new.user_id)
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

drop trigger if exists trg_notify_app_open on public.app_events;
create trigger trg_notify_app_open
  after insert on public.app_events
  for each row execute function public.notify_app_open();

-- 2. A new submission (review or new space).
create or replace function public.notify_submission()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  who text;
  space text;
begin
  if public.is_team_member(new.user_id) then return new; end if;
  select coalesce(nullif(display_name, ''), 'A nomad') into who
    from public.profiles where id = new.user_id;
  space := coalesce(
    (select name from public.venues where id = new.venue_id),
    new.payload->>'name', 'a space');
  perform public.notify_phone(
    case when new.kind = 'new_venue'
         then 'New space submitted' else 'New review' end,
    coalesce(who, 'A nomad') || ' -> ' || space,
    'tada');
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists trg_notify_submission on public.submissions;
create trigger trg_notify_submission
  after insert on public.submissions
  for each row execute function public.notify_submission();

-- 3. A new account.
create or replace function public.notify_signup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.notify_phone(
    'New Nomadmaps sign-up',
    coalesce(nullif(new.display_name, ''), 'A new nomad')
      || ' just created an account',
    'wave');
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists trg_notify_signup on public.profiles;
create trigger trg_notify_signup
  after insert on public.profiles
  for each row execute function public.notify_signup();

-- 4. Feedback arrived.
create or replace function public.notify_feedback()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.notify_phone(
    'New feedback',
    left(new.message, 160),
    'speech_balloon');
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists trg_notify_feedback on public.feedback;
create trigger trg_notify_feedback
  after insert on public.feedback
  for each row execute function public.notify_feedback();

-- Say hello so the phone setup can be verified right away.
select public.notify_phone(
  'Nomadmaps notifications are live',
  'This channel now pings you when people use the app.',
  'rocket');
