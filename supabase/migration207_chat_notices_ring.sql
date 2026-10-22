-- ============================================================
-- Migration 207: chat notices ring, and a test notice.
--
-- Jonathan, 22 Oct 2026: unsure whether the phone notices for chats
-- arrive, and he would like an audio ping for them. The notices go
-- through ntfy (the topic in notify_phone, migration 25). The chat
-- notices (website chats, owner chats, an owner in their Owner
-- account) are now sent with ntfy's "high" priority, which makes the
-- phone sound, vibrate and show the notice on top. Other notices stay
-- as they were.
--
-- admin_notify_test(): sends one test notice, the same way, so he can
-- check his phone gets them (Chats, Test phone notice).
--
-- Copies of migration 190's site_chat_notify, 161's chat_notify and
-- 198's chat_notify_open with only 'priority' added.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.site_chat_notify(p_title text, p_message text)
returns void language plpgsql security definer set search_path = public as $$
declare
  topic text;
begin
  select substring(p.prosrc from '''topic'',\s*''([^'']+)''') into topic
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notify_phone'
   limit 1;
  if topic is null then
    perform public.notify_phone(p_title, p_message, 'speech_balloon');
    return;
  end if;
  perform net.http_post(
    url := 'https://ntfy.sh',
    body := jsonb_build_object(
      'topic', topic,
      'title', p_title,
      'message', p_message,
      'priority', 4, -- high: sound and a pop-up on the phone (migration 207)
      'tags', array['speech_balloon'],
      'click', 'https://nomadmaps.io/chats/#site'),
    headers := '{"Content-Type": "application/json"}'::jsonb);
exception when others then
  null; -- a notice never gets in the way of the chat
end $$;
revoke all on function public.site_chat_notify(text, text) from public, anon, authenticated;

create or replace function public.chat_notify(p_title text, p_message text)
returns void language plpgsql security definer set search_path = public as $$
declare
  topic text;
begin
  select substring(p.prosrc from '''topic'',\s*''([^'']+)''') into topic
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notify_phone'
   limit 1;
  if topic is null then
    perform public.notify_phone(p_title, p_message, 'speech_balloon');
    return;
  end if;
  perform net.http_post(
    url := 'https://ntfy.sh',
    body := jsonb_build_object(
      'topic', topic,
      'title', p_title,
      'message', p_message,
      'priority', 4, -- high: sound and a pop-up on the phone (migration 207)
      'tags', array['speech_balloon'],
      'click', 'https://nomadmaps.io/chats/'),
    headers := '{"Content-Type": "application/json"}'::jsonb);
exception when others then
  null; -- a notice never gets in the way of the message itself
end $$;
revoke all on function public.chat_notify(text, text) from public, anon, authenticated;

create or replace function public.chat_notify_open(
  p_title text, p_message text, p_click text)
returns void language plpgsql security definer set search_path = public as $$
declare
  topic text;
begin
  select substring(p.prosrc from '''topic'',\s*''([^'']+)''') into topic
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notify_phone'
   limit 1;
  if topic is null then
    perform public.notify_phone(p_title, p_message, 'wave');
    return;
  end if;
  perform net.http_post(
    url := 'https://ntfy.sh',
    body := jsonb_build_object(
      'topic', topic,
      'title', p_title,
      'message', p_message,
      'priority', 4, -- high: sound and a pop-up on the phone (migration 207)
      'tags', array['wave'],
      'click', coalesce(p_click, 'https://nomadmaps.io/chats/')),
    headers := '{"Content-Type": "application/json"}'::jsonb);
exception when others then
  null; -- a notice never gets in the way
end $$;
revoke all on function public.chat_notify_open(text, text, text) from public, anon, authenticated;

create or replace function public.admin_notify_test()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;
  perform public.site_chat_notify('Test from Nomad Maps',
    'If you can read this (and heard it), chat notices reach your phone.');
  return jsonb_build_object('sent', true);
end $$;
revoke all on function public.admin_notify_test() from public, anon;
grant execute on function public.admin_notify_test() to authenticated;

notify pgrst, 'reload schema';
