-- Migration 191: the website chat's assistant writes plain text.
--
-- The assistant is told not to use markdown, but now and then it still
-- writes **bold** or [a link](https://...), which the chat box shows
-- as stars and brackets (Jonathan, 20 Oct 2026, a Koh Lanta chat:
-- "**Escape Cafe**"). Every assistant message is cleaned as it is
-- saved, and the ones already saved are cleaned once here.
--
-- Safe to apply more than once.

create or replace function public.site_chat_plain(p text)
returns text
language sql
immutable
as $$
  select btrim(
    regexp_replace(                                   -- leftover ** or __
      regexp_replace(                                 -- # headings
        regexp_replace(                               -- [text](url)
          regexp_replace(                             -- __bold__
            regexp_replace(coalesce(p, ''),           -- **bold**
              '\*\*([^*]+?)\*\*', '\1', 'g'),
            '__([^_]+?)__', '\1', 'g'),
          '\[([^\]]+)\]\((https?://[^)\s]+)\)', '\1: \2', 'g'),
        '(^|\n)#{1,6}\s+', '\1', 'g'),
      '\*\*|__', '', 'g'))
$$;

create or replace function public.site_chat_plain_bot()
returns trigger
language plpgsql
as $$
begin
  if new.role = 'bot' then
    new.body := public.site_chat_plain(new.body);
    if new.body = '' then
      new.body := '...';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_site_chat_plain_bot on public.site_chat_messages;
create trigger trg_site_chat_plain_bot
  before insert or update of body on public.site_chat_messages
  for each row execute function public.site_chat_plain_bot();

-- The ones already saved.
update public.site_chat_messages
   set body = public.site_chat_plain(body)
 where role = 'bot'
   and body <> public.site_chat_plain(body)
   and public.site_chat_plain(body) <> '';
