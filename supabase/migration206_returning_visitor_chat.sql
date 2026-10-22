-- ============================================================
-- Migration 206: a returning visitor starts a fresh website chat.
--
-- Jonathan, 22 Oct 2026, opening a blog article: the chat box showed
-- the old conversation, and his "hello" went to a chat that had been
-- handed to a person, so the assistant did not greet him. He wants the
-- old conversation kept in Nomad Maps, and a returning visitor to
-- start again, in a positive way.
--
-- chat.js (in the app) now starts a new chat when the last one has
-- been quiet for 12 hours, or when the visitor presses "New chat", and
-- sends the old chat's key with the first message. Here:
--   * site_chats.previous_id links the new chat to the last one, and
--     the new chat starts with their email, number, name and who they
--     are already known (so Jonathan can still reach them).
--   * The phone notice says "A returning visitor started a chat".
--   * admin_site_chat gives 'previous' (when, how many messages,
--     open or closed) for Chats to show.
-- site_chat_send is migration 192's with the new p_prev argument; the
-- old six-argument version is dropped (a cached chat.js still works:
-- p_prev has a default). admin_site_chat is migration 200's plus
-- 'previous'.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

alter table public.site_chats
  add column if not exists previous_id uuid references public.site_chats(id) on delete set null;

drop function if exists public.site_chat_send(uuid, text, text, text, bigint, text);

create or replace function public.site_chat_send(
  p_token uuid, p_body text, p_page text default null, p_title text default null,
  p_after bigint default 0, p_outline text default null, p_prev uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  msg   text := btrim(coalesce(p_body, ''));
  iph   text := public.site_chat_ip_hash();
  c     public.site_chats%rowtype;
  first boolean := false;
  em    text;
  vid   uuid;
  slug  text;
  pth   text;
  prev  public.site_chats%rowtype;
begin
  if coalesce(public.visit_blocked(), false) then
    raise exception 'The chat is not available right now.';
  end if;
  if p_token is null then raise exception 'Missing chat key.'; end if;
  if msg = '' then raise exception 'Write a message first.'; end if;
  msg := left(msg, 800);

  -- On the blog, only on the articles chosen in Nomad Maps.
  pth := lower(split_part(split_part(regexp_replace(coalesce(p_page, ''), '^https?://[^/]+', ''), '?', 1), '#', 1));
  pth := regexp_replace(pth, '/+$', '');
  if pth like '/blog/%' and not exists (select 1 from public.site_chat_pages where path = pth) then
    raise exception 'The chat is not available on this page.';
  end if;

  if iph is not null and (
       (select count(*) from public.site_chat_messages
         where ip_hash = iph and role = 'visitor'
           and at > now() - interval '1 hour') >= 15
    or (select count(*) from public.site_chat_messages
         where ip_hash = iph and role = 'visitor'
           and at > now() - interval '1 day') >= 40) then
    raise exception 'That is a lot of messages. Please try again a little later, or email hello@nomadwise.io.';
  end if;

  select * into c from public.site_chats where token = p_token for update;
  if c.id is not null then
    -- one message every 3 seconds; the same words twice in a row once
    if exists (select 1 from public.site_chat_messages
                where chat_id = c.id and role = 'visitor'
                  and at > now() - interval '3 seconds') then
      raise exception 'One moment, please.';
    end if;
    if (select body from public.site_chat_messages
         where chat_id = c.id and role = 'visitor' order by id desc limit 1) = msg then
      return public.site_chat_view(c.id, p_after);
    end if;
  end if;
  if c.id is null then
    if (iph is not null and (select count(*) from public.site_chats
                              where ip_hash = iph and started_at > now() - interval '1 day') >= 3)
       or (select count(*) from public.site_chats where started_at > now() - interval '1 hour') >= 20
       or (select count(*) from public.site_chats where started_at > now() - interval '1 day') >= 80 then
      raise exception 'The chat is busy right now. Please email hello@nomadwise.io.';
    end if;
    slug := nullif(split_part(split_part(split_part(lower(coalesce(p_page, '')), '/coworking/', 2), '?', 1), '#', 1), '');
    if slug is not null then
      select id into vid from public.venues where webflow_slug = slug limit 1;
    end if;
    -- A returning visitor (migration 206): their browser started a
    -- fresh chat and sends the key of the last one, so this one is
    -- linked to it and keeps how to reach them.
    if p_prev is not null and p_prev <> p_token then
      select * into prev from public.site_chats where token = p_prev;
    end if;
    insert into public.site_chats (token, page_url, page_title, first_page, ip_hash, venue_id,
                                   previous_id, visitor_email, visitor_phone, visitor_name, who)
    values (p_token, left(p_page, 500), left(p_title, 200), left(p_page, 500), iph, vid,
            prev.id, prev.visitor_email, prev.visitor_phone, prev.visitor_name, prev.who)
    returning * into c;
    first := true;
  end if;

  em := substring(msg from '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})');
  insert into public.site_chat_messages (chat_id, role, body, ip_hash)
  values (c.id, 'visitor', msg, iph);
  update public.site_chats
     set last_at = now(), last_seen_at = now(),
         page_url = coalesce(left(p_page, 500), page_url),
         page_title = coalesce(left(p_title, 200), page_title),
         visitor_msgs = visitor_msgs + 1,
         visitor_email = coalesce(visitor_email, lower(left(em, 200))),
         page_outline = case when p_outline is null then page_outline
                             else nullif(left(btrim(p_outline), 4000), '') end,
         status = 'open', done_at = null
   where id = c.id
  returning * into c;

  if first then
    perform public.site_chat_notify(
      case when prev.id is not null then 'A returning visitor started a chat'
           when pth like '/blog/%' then 'New chat on a blog article'
           else 'New chat on nomadwise.io' end,
      left(msg, 140) || coalesce(' (' || nullif(left(p_title, 60), '') || ')', ''));
  elsif c.mode = 'team' or c.needs_team then
    perform public.site_chat_notify('They wrote in a chat', left(msg, 140));
  end if;

  if c.mode = 'bot' then
    if public.site_chat_over_limit(c.id, iph) then
      perform public.site_chat_hold(c.id);
    else
      begin
        perform public.site_chat_ask(c.id);
      exception when others then
        perform public.site_chat_hold(c.id);
      end;
    end if;
  end if;

  return public.site_chat_view(c.id, p_after);
end $$;
revoke all on function public.site_chat_send(uuid, text, text, text, bigint, text, uuid) from public;
grant execute on function public.site_chat_send(uuid, text, text, text, bigint, text, uuid) to anon, authenticated;

create or replace function public.admin_site_chat(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'founders only'; end if;
  perform public.site_chat_settle(p_id);
  update public.site_chats set team_seen_at = now() where id = p_id;
  return (select jsonb_build_object(
      'chat', jsonb_build_object(
         'id', c.id, 'mode', c.mode, 'status', c.status, 'needs_team', c.needs_team,
         'who', c.who, 'visitor_email', c.visitor_email, 'visitor_phone', c.visitor_phone,
         'visitor_name', c.visitor_name,
         'page_url', c.page_url, 'page_title', c.page_title, 'first_page', c.first_page,
         'started_at', c.started_at, 'last_seen_at', c.last_seen_at,
         'here', c.last_seen_at > now() - interval '45 seconds',
         'typing', c.pending_req is not null, 'note', c.note,
         -- returning visitor (migration 206): their last chat
         'previous', (select jsonb_build_object('id', p.id, 'started_at', p.started_at,
                                                'status', p.status,
                                                'messages', (select count(*) from public.site_chat_messages pm
                                                              where pm.chat_id = p.id))
                        from public.site_chats p where p.id = c.previous_id)),
      'messages', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'id', m.id,
                  'team', m.role <> 'visitor',
                  'author', case when m.role = 'bot' then 'Assistant'
                                 when m.role = 'team' then coalesce(m.author, 'Jonathan')
                                 else coalesce(c.visitor_name, 'Visitor') end,
                  'role', m.role,
                  'body', m.body,
                  'at', m.at,
                  'read', m.read_at is not null,
                  'emailed', m.emailed_at is not null) order by m.id)
           from (select * from public.site_chat_messages x
                  where x.chat_id = c.id order by x.id desc limit 400) m), '[]'::jsonb))
    from public.site_chats c where c.id = p_id);
end $$;
revoke all on function public.admin_site_chat(uuid) from public, anon;
grant execute on function public.admin_site_chat(uuid) to authenticated;

notify pgrst, 'reload schema';
