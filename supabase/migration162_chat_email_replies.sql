-- Migration 162: an owner's answer by email arrives in the chat.
--
-- Jonathan, 7 Oct 2026, after the chat (migration 161): "Can we setup
-- an inbound in postmark". Until now an owner who answered the email
-- that says we wrote reached hello@, and the chat stayed silent.
--
-- How it works:
--   * Postmark gives the mail server an inbound address. Jonathan
--     keeps it in Vault under the name chat_inbound_address. While
--     that entry is missing, everything stays as it was in 161.
--   * Each chat (a space and its owner) gets a key of its own
--     (chat_reply_tokens). The email that says we wrote carries
--     Reply-To: <address>+<key>@..., so the answer says which chat it
--     belongs to. The key is the proof: nobody can guess it, and it is
--     only ever sent to that owner.
--   * Postmark hands every email that arrives there to chat_inbound
--     (the inbound webhook, called through the public API). It takes
--     the new words out of the email (not the quoted ones), puts them
--     in the chat as the owner's message, and tells the founders'
--     phones, as when the owner writes in the Owner account.
--   * Kept out of the chat, and written to chat_inbound_log instead:
--     automatic answers (out of office, bounces), emails without a
--     key, an email for a space that has changed hands, an email with
--     nothing in it, more than 40 an hour, one of us answering the
--     copy hello@ gets, and a second delivery of the same email.
--   * Found while this was checked: send_owner_email (migration 101)
--     and notify_phone (migration 25) could be called by anybody who
--     has the app's public key, which is anybody: an email from
--     hello@ to any address with any words, or a notice on the
--     founders' phones. Both are closed at the end of this file. Only
--     the database's own functions and the scripts that hold the
--     service key call them, and those go on working.
--
--   chat_reply_tokens            the key of each chat
--   chat_inbound_log             every email that arrived, and what
--                                became of it (kept 90 days)
--   space_chat_messages.via_email  the message came by email
--   chat_reply_address(...)      the Reply-To of one chat, or null
--   chat_reply_text(jsonb)       the new words of an email
--   chat_inbound(jsonb)          Postmark's webhook
--   send_owner_email_reply_to    send_owner_email with a Reply-To
--   chat_rows, chat_email_sync   re-made from 161

alter table public.space_chat_messages
  add column if not exists via_email boolean not null default false;

create table if not exists public.chat_reply_tokens (
  token       text primary key,
  venue_id    uuid not null references public.venues(id) on delete cascade,
  owner_email text not null,
  created_at  timestamptz not null default now(),
  unique (venue_id, owner_email)
);
alter table public.chat_reply_tokens enable row level security;

create table if not exists public.chat_inbound_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  message_id text,
  from_email text,
  from_name  text,
  subject    text,
  token      text,
  venue_id   uuid,
  status     text not null,
  note       text,
  body       text
);
create unique index if not exists chat_inbound_log_message
  on public.chat_inbound_log (message_id) where message_id is not null;
create index if not exists chat_inbound_log_at on public.chat_inbound_log (at);
alter table public.chat_inbound_log enable row level security;

-- The messages of one chat, oldest first (the latest 400). As in 161,
-- with "email": the message came by email.
create or replace function public.chat_rows(p_venue uuid, p_owner text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id,
           'team', m.from_team,
           'author', m.author,
           'body', m.body,
           'at', m.at,
           'read', m.read_at is not null,
           'email', m.via_email) order by m.at, m.id), '[]'::jsonb)
    from (select * from public.space_chat_messages x
           where x.venue_id = p_venue
             and (p_owner is null or x.owner_email = p_owner)
           order by x.at desc, x.id desc limit 400) m;
$$;
revoke all on function public.chat_rows(uuid, text) from public, anon, authenticated;

-- The address an owner's answer is sent to: Postmark's inbound address
-- with the chat's key after a plus sign. Null while the inbound
-- address is not in Vault (or is not an address).
create or replace function public.chat_reply_address(p_venue uuid, p_owner text)
returns text language plpgsql security definer set search_path = public as $$
declare
  base text;
  tok  text;
  em   text := lower(btrim(coalesce(p_owner, '')));
begin
  if p_venue is null or em = '' then return null; end if;
  begin
    select lower(btrim(decrypted_secret)) into base
      from vault.decrypted_secrets where name = 'chat_inbound_address' limit 1;
  exception when others then
    base := null;
  end;
  if base is null or base !~ '^[a-z0-9._-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    return null;
  end if;
  insert into public.chat_reply_tokens (token, venue_id, owner_email)
  values (replace(gen_random_uuid()::text, '-', ''), p_venue, em)
  on conflict (venue_id, owner_email) do nothing;
  select t.token into tok
    from public.chat_reply_tokens t
   where t.venue_id = p_venue and t.owner_email = em;
  if tok is null then return null; end if;
  return split_part(base, '@', 1) || '+' || tok || '@' || split_part(base, '@', 2);
end $$;
revoke all on function public.chat_reply_address(uuid, text) from public, anon, authenticated;

-- send_owner_email (migration 101) with the address answers go to.
-- The same email in every other way: sender, copy to hello@, look.
create or replace function public.send_owner_email_reply_to(
  p_to text, p_subject text, p_text text, p_kind text, p_ref text,
  p_cta_label text, p_cta_url text, p_reply_to text)
returns void language plpgsql security definer set search_path = public as $$
declare
  token text;
  req   bigint;
  dest  text := lower(trim(coalesce(p_to, '')));
  plain text := p_text;
  vid   uuid;
begin
  if dest = '' or position('@' in dest) < 2 then return; end if;
  begin
    vid := public.owner_email_venue(p_ref);
  exception when others then vid := null; end;

  if coalesce(p_cta_url, '') <> '' and position(p_cta_url in coalesce(p_text, '')) = 0 then
    plain := p_text || E'\n\n' || coalesce(p_cta_label, 'Open') || ': ' || p_cta_url;
  end if;

  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if token is null or token = '' then
    insert into public.owner_emails (kind, to_email, subject, ref, status, error, body, cta_url, venue_id)
    values (p_kind, dest, p_subject, p_ref, 'skipped',
            'No Postmark token in Vault yet (postmark_server_token).', plain, p_cta_url, vid);
    return;
  end if;

  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := jsonb_build_object(
      'From', 'Jonathan at Nomadwise <hello@nomadwise.io>',
      'To', dest,
      'Bcc', 'hello@nomadwise.io',
      'ReplyTo', coalesce(nullif(btrim(coalesce(p_reply_to, '')), ''), 'hello@nomadwise.io'),
      'Subject', p_subject,
      'TextBody', plain,
      'HtmlBody', public.owner_email_html(p_text, p_cta_label, p_cta_url),
      'MessageStream', 'outbound',
      'Tag', p_kind),
    headers := jsonb_build_object(
      'X-Postmark-Server-Token', token,
      'Accept', 'application/json',
      'Content-Type', 'application/json'))
  into req;

  insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, cta_url, venue_id)
  values (p_kind, dest, p_subject, p_ref, 'sent', req::text, plain, p_cta_url, vid);
exception when others then
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, error, body, venue_id)
    values (p_kind, coalesce(dest, '?'), coalesce(p_subject, ''), p_ref, 'failed', sqlerrm, plain, vid);
  exception when others then null; end;
end $$;
revoke all on function public.send_owner_email_reply_to(text, text, text, text, text, text, text, text)
  from public, anon, authenticated;

-- The new words of an email: what the sender wrote, without the
-- message they are answering underneath. Postmark's own cut is used
-- when it has one; then the text is cut at the first sign of a quoted
-- message. When that leaves nothing (somebody who writes under the
-- quoted message), or when answers stand between quoted lines, the
-- quoted lines are taken out and the rest is kept. No more than
-- 100,000 characters are looked at, and no pattern here can take
-- long whatever is sent: anybody can call the webhook. Never raises:
-- at worst the whole text comes back.
create or replace function public.chat_reply_text(p jsonb)
returns text language plpgsql immutable as $$
declare
  raw    text := left(coalesce(p->>'TextBody', ''), 100000);
  t      text := left(coalesce(p->>'StrippedTextReply', ''), 100000);
  whole  text;
  pat    text;
  inline boolean := false;
  -- spaces of every kind, for trimming (160 is the space that does
  -- not break a line, which some mail programs leave behind)
  ws     text := E' \n\t\r' || chr(160);
begin
  if btrim(t, ws) = '' then
    t := raw;
  end if;
  if btrim(t, ws) = '' then
    -- an email with a web version only
    t := left(coalesce(p->>'HtmlBody', ''), 300000);
    t := regexp_replace(t, '<style[^>]*?>.*?</style>', ' ', 'gi');
    t := regexp_replace(t, '<script[^>]*?>.*?</script>', ' ', 'gi');
    t := regexp_replace(t, '<head\M[^>]*?>.*?</head>', ' ', 'gi');
    t := regexp_replace(t, '<title[^>]*?>.*?</title>', ' ', 'gi');
    t := regexp_replace(t, '<blockquote.*$', '', 'i');
    t := regexp_replace(t, '<div class="gmail_quote.*$', '', 'i');
    t := regexp_replace(t, '<br[^>]*>|</p>|</div>|</li>|</tr>', E'\n', 'gi');
    t := regexp_replace(t, '<[^>]+>', '', 'g');
    t := replace(replace(replace(replace(replace(replace(
           t, '&nbsp;', ' '), '&lt;', '<'), '&gt;', '>'),
           '&quot;', '"'), '&#39;', ''''), '&amp;', '&');
  end if;
  -- no more is looked at than anybody writes: the chat shows 3,700
  -- characters, and the work below stays short whatever arrives
  t := left(t, 100000);
  t := replace(replace(t, E'\r\n', E'\n'), E'\r', E'\n');
  -- (a line break in front, so "at the start of a line" also means
  -- the very first line)
  t := E'\n' || t;
  -- The whole email as it was written, for the answers that are not
  -- at the top of it (Postmark's own cut stops at the first quote).
  whole := case when btrim(raw, ws) <> ''
                then E'\n' || replace(replace(raw, E'\r\n', E'\n'), E'\r', E'\n')
                else t end;
  foreach pat in array array[
    -- our own email, quoted without any mark
    '\n[^\n]*Nomadwise sent you a message about',
    -- "On Tue, 7 Oct 2026 at 17:43, Jonathan <hello@...> wrote:" as
    -- the end of a line, also over two lines, and in the languages
    -- owners write in.
    -- A date is part of every such line: "On Google a guest wrote:"
    -- in the owner's own words is not one.
    '\nOn [^\n0-9]{0,60}[0-9][^\n]{0,250}(\n[^\n]{0,250})?wrote:[ \t]*(\n|$)',
    '\nLe [^\n0-9]{0,60}[0-9][^\n]{0,250}(\n[^\n]{0,250})?a .crit ?:[ \t]*(\n|$)',
    '\nEl [^\n0-9]{0,60}[0-9][^\n]{0,250}(\n[^\n]{0,250})?escribi.:[ \t]*(\n|$)',
    '\nEm [^\n0-9]{0,60}[0-9][^\n]{0,250}(\n[^\n]{0,250})?escreveu:[ \t]*(\n|$)',
    '\nA [^\n0-9]{0,60}[0-9][^\n]{0,250}(\n[^\n]{0,250})?escreveu:[ \t]*(\n|$)',
    '\nAm [^\n0-9]{0,60}[0-9][^\n]{0,250}(\n[^\n]{0,250})?schrieb[^\n]{0,200}:[ \t]*(\n|$)',
    '\nIl [^\n0-9]{0,60}[0-9][^\n]{0,250}(\n[^\n]{0,250})?ha scritto:[ \t]*(\n|$)',
    '\nOp [^\n0-9]{0,60}[0-9][^\n]{0,250}(\n[^\n]{0,250})?schreef[^\n]{0,200}:[ \t]*(\n|$)',
    -- the block other mail programs put above a quoted message
    '\n-{2,} ?(Original Message|Forwarded message|Mensagem original|Mensaje original|Message d.origine|Urspr.ngliche Nachricht) ?-{2,}',
    '\n_{8,}[ \t]*\n',
    '\n(From|De|Von|Da|Van) ?: [^\n]+\n(Sent|Date|Enviado|Enviada|Enviada em|Envoy.|Gesendet|Inviato|Verzonden|Fecha|Data|Datum) ?: ',
    -- the line that names us as the writer of what follows (Gmail
    -- breaks the line after the "<" when it is long)
    '\n[^\n]*<\n?hello@nomadwise\.io>',
    -- quoted lines
    '\n>',
    -- a signature, by the usual mark
    '\n-- \n'
  ] loop
    begin
      t := regexp_replace(t, pat || '.*$', '', 'i');
    exception when others then
      -- one sign that cannot be looked for does not stop the others
      null;
    end;
  end loop;

  -- answers written between the quoted lines: a quoted line, words of
  -- their own, a quoted line again
  inline := whole ~ '\n>[^\n]*\n([ \t]*\n)*[^>\n \t][^\n]*\n([^>\n][^\n]*\n|\n)*>';

  if inline or btrim(t, ws) = '' then
    -- written under or between the quoted lines: keep what is not quoted
    t := whole;
    t := regexp_replace(t, '\n>[^\n]*', '', 'g');
    t := regexp_replace(t, '\nOn [^\n]{0,250}(\n[^\n]{0,250})?wrote:[ \t]*(\n|$)', E'\n', 'gi');
    t := regexp_replace(t, '\n[^\n]*<\n?hello@nomadwise\.io>[^\n]*', '', 'gi');
    t := regexp_replace(t, '\n-- \n.*$', '');
  end if;

  -- what phones add by themselves
  t := regexp_replace(t,
         '\n(Sent from my [^\n]{1,40}|Sent from Outlook[^\n]{0,40}|Get Outlook for [^\n]{1,40}|Enviado do meu [^\n]{1,40}|Enviado desde mi [^\n]{1,40}|Envoy. de mon [^\n]{1,40}|Von meinem [^\n]{1,40} gesendet)\s*$',
         '', 'i');
  t := regexp_replace(t, '[ \t]+\n', E'\n', 'g');
  t := regexp_replace(t, '\n{3,}', E'\n\n', 'g');
  return btrim(t, ws);
exception when others then
  return left(btrim(coalesce(p->>'TextBody', ''), E' \n\t\r'), 100000);
end $$;
revoke all on function public.chat_reply_text(jsonb) from public, anon, authenticated;

-- Postmark's inbound webhook: one email that arrived at the inbound
-- address, as Postmark describes it. Called without a sign-in (the
-- key in the address is what is checked), and always answers "ok":
-- an error would only make Postmark deliver the same email again.
-- Because anybody can call it: nothing is worked out from an email
-- without a key we gave out, such emails are counted apart (30 an
-- hour are kept, the rest let go) so they cannot stand in the way of
-- an owner's answer, and the phones are told about them at most once
-- a day for each sender and five times a day in all.
create or replace function public.chat_inbound(jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p        alias for $1;
  mid      text;
  from_em  text;
  from_nm  text;
  subj     text;
  tok      text;
  k        public.chat_reply_tokens%rowtype;
  v        public.venues%rowtype;
  owner_em text;
  words    text;
  files    integer := 0;
  auto     boolean := false;
  known    boolean := false;
  log_id   bigint;
  who      text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return jsonb_build_object('ok', true);
  end if;
  mid     := nullif(left(btrim(coalesce(p->>'MessageID', '')), 200), '');
  from_em := nullif(left(lower(btrim(coalesce(p #>> '{FromFull,Email}', p->>'From', ''))), 200), '');
  from_nm := nullif(left(btrim(coalesce(p #>> '{FromFull,Name}', p->>'FromName', '')), 80), '');
  subj    := left(btrim(coalesce(p->>'Subject', '')), 200);

  -- the key of the chat: what stands after the plus sign
  tok := lower(btrim(coalesce(p->>'MailboxHash', '')));
  if tok !~ '^[0-9a-f]{32}$' then
    tok := substring(lower(concat_ws(' ', p->>'OriginalRecipient', p->>'To', p->>'Cc'))
                     from '\+([0-9a-f]{32})@');
  end if;

  -- Whose email it is comes first: with a key we gave out it is an
  -- owner's, without one it is anybody's.
  if tok is not null then
    select * into k from public.chat_reply_tokens t where t.token = tok;
  end if;
  known := k.token is not null;

  -- Not a flood. The two kinds are counted apart, so that what arrives
  -- without a key can never stand in the way of an owner's answer.
  if known then
    if (select count(*) from public.chat_inbound_log l
         where l.at > now() - interval '1 hour' and l.venue_id = k.venue_id) >= 120 then
      return jsonb_build_object('ok', true);
    end if;
  elsif (select count(*) from public.chat_inbound_log l
          where l.at > now() - interval '1 hour' and l.venue_id is null) >= 30 then
    return jsonb_build_object('ok', true);
  end if;

  -- One line per email. A second delivery of the same one stops here.
  insert into public.chat_inbound_log (message_id, from_email, from_name, subject, token, venue_id, status)
  values (mid, from_em, from_nm, subj, tok, k.venue_id, 'new')
  on conflict (message_id) where message_id is not null do nothing
  returning id into log_id;
  if log_id is null then
    return jsonb_build_object('ok', true);
  end if;

  begin
    -- an automatic answer is not the owner writing
    if jsonb_typeof(p->'Headers') = 'array' then
      select exists (
        select 1 from jsonb_array_elements(p->'Headers') h
         where (lower(h->>'Name') = 'auto-submitted'
                and lower(btrim(coalesce(h->>'Value', ''))) not like 'no%')
            or lower(h->>'Name') in ('x-autoreply', 'x-autorespond', 'x-auto-reply')
            or (lower(h->>'Name') = 'precedence'
                and lower(btrim(coalesce(h->>'Value', ''))) in ('bulk', 'junk', 'auto_reply', 'list'))
      ) into auto;
    end if;
    if not auto then
      auto := subj ~* '^\s*(auto(matic)?[ -]?(reply|response)|out of (the )?office|abwesenheit|automatische antwort|respuesta autom|r.ponse automatique|resposta autom|risposta automatica|automatisch antwoord|ausente|fora do escrit|undeliverable|delivery status notification|mail delivery (failed|subsystem)|failure notice)'
           or coalesce(from_em, '') ~ '^(mailer-daemon|postmaster|no-?reply|do-?not-?reply|bounces?)[^@]*@';
    end if;
    if auto then
      update public.chat_inbound_log set status = 'auto',
             note = 'An automatic answer: not put in the chat.'
       where id = log_id;
      return jsonb_build_object('ok', true);
    end if;

    -- One of us answering the copy that hello@ gets is not the owner.
    if coalesce(from_em, '') ~ '@nomadwise\.io$' then
      update public.chat_inbound_log set status = 'ours',
             note = 'From our own address: not put in the chat.'
       where id = log_id;
      return jsonb_build_object('ok', true);
    end if;

    if not known then
      -- No key, or one we never gave out. Nothing is worked out from
      -- such an email; the start of it is kept. The phones are told
      -- only when the sender is a known owner, once a day for each
      -- sender and five times a day in all: anybody can write to the
      -- address, under any name.
      update public.chat_inbound_log set status = 'no_chat',
             note = 'No chat key in the address.',
             body = left(btrim(coalesce(nullif(p->>'StrippedTextReply', ''), p->>'TextBody', ''),
                               E' \n\t\r'), 500)
       where id = log_id;
      if from_em is not null
         and exists (select 1 from public.venues x
                      where lower(btrim(coalesce(x.listing_owner_email, ''))) = from_em)
         and not exists (select 1 from public.chat_inbound_log l
                          where l.id <> log_id and l.status = 'no_chat'
                            and l.from_email = from_em
                            and l.at > now() - interval '1 day')
         and (select count(*) from public.chat_inbound_log l
               where l.status = 'no_chat' and l.note like '%The phones were told.'
                 and l.at > now() - interval '1 day') < 5 then
        update public.chat_inbound_log
           set note = 'No chat key in the address. The phones were told.'
         where id = log_id;
        perform public.chat_notify(
          'Chat: an email that fits no chat',
          'An email from ' || from_em
            || ' could not be put in a chat. It is in Postmark, under Inbound.');
      end if;
      return jsonb_build_object('ok', true);
    end if;

    words := public.chat_reply_text(p);

    select * into v from public.venues x where x.id = k.venue_id;
    owner_em := nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '');
    if v.id is null or owner_em is null or owner_em <> k.owner_email then
      update public.chat_inbound_log set status = 'not_owner',
             note = 'The space is no longer on this owner''s account.',
             body = left(words, 2000)
       where id = log_id;
      -- once a day for each space
      if not exists (select 1 from public.chat_inbound_log l
                      where l.id <> log_id and l.status = 'not_owner'
                        and l.venue_id = k.venue_id
                        and l.at > now() - interval '1 day') then
        perform public.chat_notify(
          'Chat: an email from a former owner',
          coalesce(from_nm, 'Somebody') || ' answered by email about '
            || coalesce(v.name, 'a space')
            || ', which is no longer on their account. It is in Postmark, under Inbound.');
      end if;
      return jsonb_build_object('ok', true);
    end if;

    -- Files that came with it. A picture inside a signature is not
    -- one: small pictures placed in the text are left out of the count.
    if jsonb_typeof(p->'Attachments') = 'array' then
      select count(*) into files
        from jsonb_array_elements(p->'Attachments') a
       where coalesce(a->>'ContentID', '') = ''
          or (case when a->>'ContentLength' ~ '^[0-9]{1,15}$'
                   then (a->>'ContentLength')::bigint else 0 end) > 60000;
    end if;

    if words = '' and files = 0 then
      update public.chat_inbound_log set status = 'empty',
             note = 'Nothing new in the email.',
             body = left(btrim(coalesce(p->>'TextBody', ''), E' \n\t\r'), 2000)
       where id = log_id;
      return jsonb_build_object('ok', true);
    end if;

    -- as many an hour as in the Owner account (owner_chat_send)
    perform pg_advisory_xact_lock(hashtextextended('space_chat:' || v.id::text, 0));
    if (select count(*) from public.space_chat_messages m
         where m.venue_id = v.id and not m.from_team
           and m.at > now() - interval '1 hour') >= 40 then
      update public.chat_inbound_log set status = 'rate',
             note = 'More than 40 messages in an hour.', body = left(words, 2000)
       where id = log_id;
      return jsonb_build_object('ok', true);
    end if;

    if char_length(words) > 3700 then
      words := left(words, 3700) || E'\n\n'
            || '[The email was longer. The rest is not shown here.]';
    end if;
    if files > 0 then
      words := case when words = '' then '' else words || E'\n\n' end
            || '[' || files || case when files = 1 then ' file' else ' files' end
            || ' came with this email. Files are not shown in the chat.]';
    end if;

    who := case when from_em is not null and from_em <> owner_em
                then coalesce(from_nm, from_em)
                else coalesce(nullif(btrim(coalesce(v.listing_owner_name, '')), ''), from_nm) end;

    insert into public.space_chat_messages
      (venue_id, from_team, author, author_email, owner_email, body, via_email)
    values (v.id, false, left(who, 80), coalesce(from_em, owner_em), owner_em, words, true);

    update public.space_chat_messages
       set read_at = now()
     where venue_id = v.id and from_team and read_at is null
       and owner_email = owner_em and emailed_at is not null;

    update public.chat_inbound_log set status = 'chat'
     where id = log_id;

    perform public.chat_notify(
      'Chat: ' || coalesce(v.name, 'a space'),
      coalesce(who, 'The owner') || ' answered by email. Tap to open the chats.');
  exception when others then
    -- kept, with the reason and the words; Postmark is not asked to
    -- try again, so the phones are told when it was an owner's (once
    -- a day for each space)
    begin
      update public.chat_inbound_log
         set status = 'error', note = left(sqlerrm, 300),
             body = coalesce(body, left(words, 2000))
       where id = log_id;
      if known and not exists (
           select 1 from public.chat_inbound_log l
            where l.id <> log_id and l.status = 'error'
              and l.venue_id = k.venue_id
              and l.at > now() - interval '1 day') then
        perform public.chat_notify(
          'Chat: an email that could not be read',
          'An owner answered by email, and it could not be put in the chat. '
            || 'It is in Postmark, under Inbound.');
      end if;
    exception when others then null; end;
  end;
  return jsonb_build_object('ok', true);
exception when others then
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.chat_inbound(jsonb) from public;
grant execute on function public.chat_inbound(jsonb) to anon, authenticated, service_role;

-- The email that says we wrote (as in 161), now with the address an
-- answer goes to when there is one, and the words to match.
create or replace function public.chat_email_sync()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r     record;
  n     integer := 0;
  who   text;
  words text;
  addr  text;
  subj  text;
  body  text;
begin
  -- read already: nothing to send
  update public.space_chat_messages
     set emailed_at = now()
   where from_team and emailed_at is null and read_at is not null;

  -- the log of arrived emails is kept 90 days; what came without a
  -- key (anybody's), 7 days
  delete from public.chat_inbound_log
   where at < now() - interval '90 days'
      or (venue_id is null and at < now() - interval '7 days');

  for r in
    select m.venue_id, m.owner_email, v.name,
           nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '') as em
      from public.space_chat_messages m
      join public.venues v on v.id = m.venue_id
     where m.from_team and m.emailed_at is null
     group by m.venue_id, m.owner_email, v.name, v.listing_owner_email
    having max(m.at) < now() - interval '60 seconds'
     order by min(m.at)
     limit 40
  loop
    begin
      -- marked and read in one statement: what is marked is exactly
      -- what is sent, and a second run finds nothing left to send
      with marked as (
        update public.space_chat_messages x
           set emailed_at = now()
         where x.venue_id = r.venue_id and x.from_team and x.emailed_at is null
           and x.owner_email is not distinct from r.owner_email
        returning x.id, x.at, x.author, x.body, x.read_at)
      select (array_agg(k.author order by k.at desc, k.id desc)
                filter (where k.author is not null))[1],
             string_agg(k.body, E'\n\n' order by k.at, k.id)
        into who, words
        from marked k
       where k.read_at is null;
      -- only to the owner it was written for, if the space is still theirs
      if words is not null and r.em is not null and r.em = r.owner_email then
        addr := public.chat_reply_address(r.venue_id, r.em);
        subj := coalesce(who || ' from Nomadwise', 'Nomadwise')
                || ' sent you a message about ' || coalesce(r.name, 'your space');
        body := subj || ':'
                || E'\n\n' || case when char_length(words) > 6000
                                     then left(words, 6000) || E'\n\n' || '(The rest is in the chat.)'
                                     else words end
                || E'\n\n';
        if addr is not null then
          perform public.send_owner_email_reply_to(
            r.em, subj,
            body || 'To answer, reply to this email, or open the chat in your '
                 || 'Owner account, under Inbox & support.',
            'chat', r.venue_id::text,
            'Open the chat', 'https://nomadmaps.io/owner?chat=' || r.venue_id::text,
            addr);
        else
          perform public.send_owner_email(
            r.em, subj,
            body || 'You can answer in your Owner account, under Inbox & support. '
                 || 'If you reply to this email instead, it reaches us too.',
            'chat', r.venue_id::text,
            'Open the chat', 'https://nomadmaps.io/owner?chat=' || r.venue_id::text);
        end if;
        n := n + 1;
      end if;
    exception when others then
      -- one space's email must not stop the others; tried again next run
      null;
    end;
  end loop;
  return n;
end $$;
revoke all on function public.chat_email_sync() from public, anon, authenticated;
grant execute on function public.chat_email_sync() to service_role;

-- ---------------------------------------------------------------
-- Two doors that were open (see the top of this file). Every function
-- in public can be called through the API by anybody unless that is
-- taken away, and for these two it never was. Each is only meant for
-- the database's own functions (all of which run with the owner's
-- rights, so they are not affected) and for the scripts that hold the
-- service key (stripe_sync.py calls notify_phone).
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('send_owner_email', 'notify_phone')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
