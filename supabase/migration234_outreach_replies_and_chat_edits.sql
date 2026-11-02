-- ============================================================
-- Migration 234: outreach replies log themselves, a reminder for
-- spaces waiting on us, changing a chat message before it goes, and
-- "Owner account" as a link in the "changes are live" email (CR-17).
-- (Applied automatically by the build; nothing to paste.)
--
-- 1. chat_inbound: an email with no chat key, from an address that is
--    a space's in Outreach (space_contacts.email), is put on that
--    space's box as "They wrote" and the box moves to Replied, as the
--    "They replied" button does. Automatic answers (out of office) and
--    our own addresses are left out, as before. The phones are told,
--    once an hour per space. For this to happen, hello@ forwards its
--    mail to the Postmark inbound address (a rule in the mailbox).
--    What anybody else sends hello@ is no longer kept in
--    chat_inbound_log beyond who and the subject (7 days, as before).
-- 2. admin_next_up: 'replied_wait', the spaces in Replied for two days
--    or more, for the "Next up" card.
-- 3. chat_rows: 'unsent' on our messages not yet emailed nor read;
--    admin_chat_edit and admin_chat_delete change or take back one.
-- 4. owner_draft_emails ("changes are live"): no "Your page: <link>"
--    line (the See my page button is there), and "Owner account" is a
--    link in words. email_html and send_owner_email understand
--    [words](https://...): linked words in the email, "words (link)"
--    in its plain text.
-- The rest of each function as before (chat_inbound and chat_rows
-- from 162, admin_next_up from 221, owner_draft_emails from 108,
-- send_owner_email from 177; email_html patched where it stands).
-- Pure ASCII. Safe to apply twice.
-- ============================================================

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
  cid      uuid;
  cname    text;
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

  -- No key, from a space in Outreach (migration 234): its answer to an
  -- outreach email, forwarded from hello@. The box written to last.
  if not known and from_em is not null and from_em !~ '@nomadwise\.io$' then
    select c.id, c.space_name into cid, cname
      from public.space_contacts c
     where lower(btrim(coalesce(c.email, ''))) = from_em
     order by c.last_out_at desc nulls last, c.created_at desc
     limit 1;
  end if;

  -- Not a flood. The two kinds are counted apart, so that what arrives
  -- without a key can never stand in the way of an owner's answer.
  if known then
    if (select count(*) from public.chat_inbound_log l
         where l.at > now() - interval '1 hour' and l.venue_id = k.venue_id) >= 120 then
      return jsonb_build_object('ok', true);
    end if;
  elsif cid is null and (select count(*) from public.chat_inbound_log l
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

    if not known and cid is not null then
      -- A space answering us: on its box in Outreach, which moves to
      -- Replied as "They replied" does. Only what is new in the email.
      words := public.chat_reply_text(p);
      if jsonb_typeof(p->'Attachments') = 'array' then
        select count(*) into files
          from jsonb_array_elements(p->'Attachments') a
         where coalesce(a->>'ContentID', '') = ''
            or (case when a->>'ContentLength' ~ '^[0-9]{1,15}$'
                     then (a->>'ContentLength')::bigint else 0 end) > 60000;
      end if;
      if files > 0 then
        words := case when words = '' then '' else words || E'\n\n' end
              || '[' || files || case when files = 1 then ' file' else ' files' end
              || ' came with this email.]';
      end if;
      if words = '' then
        words := '[An email with nothing new in it: ' || coalesce(nullif(subj, ''), 'no subject') || ']';
      end if;
      insert into public.outreach_messages (contact_id, direction, subject, body, at, sent_by)
      values (cid, 'in', nullif(subj, ''), left(words, 4000), now(), 'email');
      update public.space_contacts
         set last_in_at = greatest(coalesce(last_in_at, now()), now()),
             first_in_at = coalesce(first_in_at, now()),
             stage = case when stage in ('contacted', 'not_now') then 'replied' else stage end
       where id = cid;
      update public.chat_inbound_log set status = 'outreach',
             note = 'Logged on the box in Outreach.'
       where id = log_id;
      -- the phones, once an hour for each space
      if not exists (select 1 from public.chat_inbound_log l
                      where l.id <> log_id and l.status = 'outreach'
                        and l.from_email = from_em
                        and l.at > now() - interval '1 hour') then
        perform public.chat_notify(
          'Outreach: ' || coalesce(cname, 'a space') || ' wrote back',
          coalesce(from_nm, from_em) || ' answered. It is on their box in Outreach.');
      end if;
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
             -- the start of it only when it is from a known owner
             -- (migration 234): what anybody else sends hello@ is not kept
             body = case when from_em is not null
                          and exists (select 1 from public.venues x
                                       where lower(btrim(coalesce(x.listing_owner_email, ''))) = from_em)
                         then left(btrim(coalesce(nullif(p->>'StrippedTextReply', ''), p->>'TextBody', ''),
                                         E' \n\t\r'), 500) end
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

create or replace function public.chat_rows(p_venue uuid, p_owner text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id,
           'team', m.from_team,
           'author', m.author,
           'body', m.body,
           'at', m.at,
           'read', m.read_at is not null,
           'email', m.via_email,
           -- ours, not yet emailed nor read: can still be changed (234)
           'unsent', m.from_team and m.read_at is null and m.emailed_at is null) order by m.at, m.id), '[]'::jsonb)
    from (select * from public.space_chat_messages x
           where x.venue_id = p_venue
             and (p_owner is null or x.owner_email = p_owner)
           order by x.at desc, x.id desc limit 400) m;
$$;

revoke all on function public.chat_rows(uuid, text) from public, anon, authenticated;

create or replace function public.owner_draft_emails()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  space text;
  url   text;
  subj  text;
  body  text;
  kind  text;
  sig   text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
  cta_label text;
  cta_url   text;
  em        text := lower(coalesce(new.owner_email, ''));
  -- Their Owner account with their email already filled in, so signing
  -- in is one tap: they press "Email me a sign-in link" and open it.
  acct      text := 'https://nomadmaps.io/owner?email='
                    || replace(replace(lower(coalesce(new.owner_email, '')), '+', '%2B'), '@', '%40');
  how       text;
begin
  if tg_op <> 'UPDATE' or old.status = new.status then return new; end if;
  select v.name into space from public.venues v where v.id = new.venue_id;
  space := coalesce(space, 'your space');
  -- Only set when the page is live (migration 108).
  url := public.owner_page_url(new.venue_id);
  how := E'\n\n' || 'To sign in, open the link above and press "Email me a sign-in link": '
      || 'we send a link to ' || em || ', no password needed.'
      || case when em like '%@gmail.com' or em like '%@googlemail.com'
              then ' As it is a Gmail address, "Continue with Google" works too.' else '' end
      || ' After that you stay signed in on that device: bookmark '
      || 'nomadmaps.io/owner to come straight back.';

  if new.status = 'applied' then
    kind := 'changes_live';
    cta_label := case when url is not null then 'See my page' else 'Open my Owner account' end;
    cta_url := coalesce(url, acct);
    subj := case when url is not null
                 then 'Your changes to ' || space || ' are on the page'
                 else 'Your changes to ' || space || ' are approved' end;
    body := 'Hi,' || E'\n\n'
         || 'Thank you for updating ' || space || '. '
         || case when url is not null
                 then 'Your changes are going onto the page now; give it a few minutes to show.'
                 else 'Your changes are approved and saved. They will be on your page '
                      || 'when it goes live, and we will email you the link then.' end
         -- "Owner account" is the link (migration 234)
         || E'\n\n' || 'Anything else to change, it is all in your [Owner account]('
         || acct || ').' || how
         || sig;
  elsif new.status = 'declined' then
    kind := 'changes_back';
    cta_label := 'Open my Owner account'; cta_url := acct;
    subj := 'A quick note about your changes to ' || space;
    body := 'Hi,' || E'\n\n'
         || 'Thank you for updating ' || space || '. Before we put your changes on '
         || 'the page, we have a small suggestion.'
         || case when coalesce(new.review_note, '') <> ''
                 then E'\n\n' || new.review_note else '' end
         || E'\n\n'
         || 'Your changes are saved in your Owner account. Sign in, adjust them and '
         || 'submit again, and we will put them straight on: '
         || acct || how
         || case when url is not null then E'\n\n' || 'Your page as it is today: ' || url else '' end
         || E'\n\n' || 'Any questions, just reply to this email.'
         || sig;
  else
    return new;
  end if;

  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);
  return new;
exception when others then
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, error)
    values ('owner_draft_email', coalesce(lower(new.owner_email), '?'),
            'Owner changes email', new.id::text, 'failed', left(sqlerrm, 300));
  exception when others then null; end;
  return new;
end $$;

create or replace function public.send_owner_email(
  p_to text, p_subject text, p_text text, p_kind text, p_ref text default null,
  p_cta_label text default null, p_cta_url text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  token text;
  req   bigint;
  pl    jsonb;
  dest  text := lower(trim(coalesce(p_to, '')));
  plain text := p_text;
  vid   uuid;
begin
  if dest = '' or position('@' in dest) < 2 then return; end if;
  begin
    vid := public.owner_email_venue(p_ref);
  exception when others then vid := null; end;

  -- A link in words, [Owner account](https://...), reads as
  -- "Owner account (https://...)" in the plain text (migration 234).
  plain := regexp_replace(plain, '\[([^]\n]{1,80})\]\((https?://[^)[:space:]]+)\)', '\1 (\2)', 'g');

  -- The button's address also goes into the plain text, so a reader
  -- without HTML still has somewhere to go.
  if coalesce(p_cta_url, '') <> '' and position(p_cta_url in coalesce(p_text, '')) = 0 then
    plain := plain || E'\n\n' || coalesce(p_cta_label, 'Open') || ': ' || p_cta_url;
  end if;

  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if token is null or token = '' then
    insert into public.owner_emails (kind, to_email, subject, ref, status, error, body, cta_url, venue_id)
    values (p_kind, dest, p_subject, p_ref, 'skipped',
            'No Postmark token in Vault yet (postmark_server_token).', plain, p_cta_url, vid);
    return;
  end if;

  -- kept with the row, so a send that failed on the way can be
  -- tried again as it was (migration 177)
  pl := jsonb_build_object(
      'From', 'Jonathan at Nomadwise <hello@nomadwise.io>',
      'To', dest,
      'Bcc', 'hello@nomadwise.io',
      'ReplyTo', 'hello@nomadwise.io',
      'Subject', p_subject,
      'TextBody', plain,
      'HtmlBody', public.owner_email_html(p_text, p_cta_label, p_cta_url),
      'MessageStream', 'outbound',
      'Tag', p_kind);

  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := pl,
    headers := jsonb_build_object(
      'X-Postmark-Server-Token', token,
      'Accept', 'application/json',
      'Content-Type', 'application/json'))
  into req;

  insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, cta_url, venue_id, payload, attempts, last_try_at)
  values (p_kind, dest, p_subject, p_ref, 'sent', req::text, plain, p_cta_url, vid, pl, 1, now());
exception when others then
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, error, body, venue_id)
    values (p_kind, coalesce(dest, '?'), coalesce(p_subject, ''), p_ref, 'failed', sqlerrm, plain, vid);
  exception when others then null; end;
end $$;

create or replace function public.admin_next_up()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  out   jsonb := '{}'::jsonb;
  part  jsonb;
  look_ids uuid[];
  sign_ids uuid[];
  pages jsonb;
  cand  jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;

  -- Text upgrades waiting for a Go: how many, on how many pages, and
  -- the most promising page among them.
  begin
    select jsonb_build_object(
             'n', coalesce(sum(t.waiting), 0),
             'pages', count(*),
             'venue_id', (array_agg(t.id order by t.impact desc, t.name))[1],
             'name', (array_agg(t.name order by t.impact desc, t.name))[1],
             'waiting', (array_agg(t.waiting order by t.impact desc, t.name))[1])
      into part
      from (select v.id, v.name, count(*) as waiting,
                   public.upgrade_impact(v, 'description') as impact
              from public.page_upgrades u
              join public.venues v on v.id = u.venue_id
             where u.kind <> 'photos' and u.status in ('proposed', 'failed')
             group by v.id) t;
    out := out || jsonb_build_object('drafts', part);
  exception when others then
    null;
  end;

  -- Price changes waiting for a Go: the first space as Price check
  -- lists them (by name).
  begin
    select jsonb_build_object(
             'n', coalesce(sum(t.waiting), 0),
             'spaces', count(*),
             'venue_id', (array_agg(t.id order by t.name, t.id))[1],
             'name', (array_agg(t.name order by t.name, t.id))[1],
             'waiting', (array_agg(t.waiting order by t.name, t.id))[1])
      into part
      from (select v.id, v.name, count(*) as waiting
              from public.product_changes c
              join public.venues v on v.id = c.venue_id
             where c.status in ('proposed', 'failed')
             group by v.id) t;
    out := out || jsonb_build_object('prices', part);
  exception when others then
    null;
  end;

  -- Pages short of photos, as "Add photos" lists them, without the
  -- ones whose new photos are already on their way.
  begin
    select jsonb_build_object(
             'n', count(*),
             'venue_id', (array_agg(t.id order by t.impact desc, t.photos, t.name))[1],
             'name', (array_agg(t.name order by t.impact desc, t.photos, t.name))[1],
             'photos', (array_agg(t.photos order by t.impact desc, t.photos, t.name))[1])
      into part
      from (select v.id, v.name, (f.facts ->> 'photos')::int as photos,
                   public.upgrade_impact(v, 'photos') as impact
              from public.venues v
              join public.venue_page_facts f on f.venue_id = v.id
             where public.upgrade_page_is_live(v)
               and (f.facts ->> 'photos') is not null
               and (f.facts ->> 'photos')::int < 5
               and not public.upgrade_owner_photos(v)
               and not exists (select 1 from public.page_upgrades u
                                where u.venue_id = v.id and u.kind = 'photos'
                                  and u.status in ('proposed', 'approved',
                                                   'failed', 'undo_requested'))) t;
    out := out || jsonb_build_object('photos', part);
  exception when others then
    null;
  end;

  -- The first page of "Choose a page" not dealt with yet (migration
  -- 142), and how many such pages the list holds (it shows 300).
  begin
    pages := public.admin_upgrades_pages(null, null, 300);
    select jsonb_build_object(
             'n', count(*),
             'more', jsonb_array_length(pages) >= 300,
             'venue_id', (array_agg(x ->> 'venue_id' order by ord))[1],
             'name', (array_agg(x ->> 'name' order by ord))[1],
             'reason', (array_agg(x ->> 'reason' order by ord))[1])
      into part
      from jsonb_array_elements(pages) with ordinality t(x, ord)
     where (x ->> 'section')::int = 1;
    out := out || jsonb_build_object('page', part);
  exception when others then
    null;
  end;

  -- The best bet on the Candidates list, and how many wait.
  begin
    cand := public.admin_candidates(null, 1, 0, 'best');
    out := out || jsonb_build_object('candidate', jsonb_build_object(
      'n', coalesce((cand ->> 'total')::int, 0),
      'place', cand -> 'rows' -> 0 ->> 'google_place_id',
      'name', cand -> 'rows' -> 0 ->> 'name',
      'area', cand -> 'rows' -> 0 ->> 'area',
      'coworking', coalesce((cand -> 'rows' -> 0 ->> 'coworking')::boolean, false),
      'mentions', coalesce((cand -> 'rows' -> 0 ->> 'mentions')::int, 0),
      'searches', (cand -> 'rows' -> 0 ->> 'searches')::int));
  exception when others then
    null;
  end;

  -- A space whose claim page was opened in the last two weeks and
  -- that is still to follow up (migration 153): how many, and the
  -- latest one.
  begin
    -- (the one named is the nearest to its space, then the latest)
    select jsonb_build_object(
             'n', count(*),
             'name', (array_agg(t.name order by t.rk, t.last_at desc))[1],
             'at', max(t.last_at),
             'opens', (array_agg(t.opens order by t.rk, t.last_at desc))[1],
             'local', count(*) filter (where t.rk <= 1),
             'where', (array_agg(t.geo ->> 'words' order by t.rk, t.last_at desc))[1]),
           array_agg(t.venue_id)
      into part, look_ids
      from (select z.*,
                   case z.geo ->> 'near' when 'near' then 0 when 'country' then 1
                                         when 'far' then 3 else 2 end as rk
              from (select l.venue_id, max(v.name) as name, max(l.last_at) as last_at,
                           max(l.opens) as opens,
                           public.claim_look_geo(l.venue_id, max(l.last_at)) as geo
                      from public.claim_look_lines() l
                      join public.venues v on v.id = l.venue_id
                     where l.last_at > now() - interval '14 days'
                     group by l.venue_id) z) t;
    out := out || jsonb_build_object('claim_look', part);
  exception when others then
    null;
  end;

  -- An account made on the map in the last two weeks that is plainly a
  -- listed space's, still to follow up (migration 154).
  begin
    select jsonb_build_object(
             'n', count(*),
             'name', (array_agg(v.name order by s.signed_up_at desc))[1],
             'at', max(s.signed_up_at)),
           array_agg(s.venue_id)
      into part, sign_ids
      from public.signup_lines() s
      join public.venues v on v.id = s.venue_id
     where s.signed_up_at > now() - interval '14 days';
    out := out || jsonb_build_object('signup', part);
  exception when others then
    null;
  end;

  -- A page we put live in the last 60 days whose space has not heard
  -- from us yet (migration 221): say hello, by email, or WhatsApp when
  -- there is no address. The newest first.
  begin
    select jsonb_build_object(
             'n', count(*),
             'with_email', count(*) filter (where coalesce(c.email, '') <> ''),
             'name', (array_agg(v.name order by v.new_page_live_at desc))[1],
             'at', max(v.new_page_live_at))
      into part
      from public.venues v
      join public.space_contacts c on c.venue_id = v.id
     where v.new_page_live_at > now() - interval '60 days'
       and not c.is_test
       and not public.outreach_aside(c.topic, c.stage)
       and c.stage = 'new'
       and c.last_out_at is null
       and c.last_in_at is null
       and btrim(coalesce(v.listing_owner_email, '')) = '';
    out := out || jsonb_build_object('new_page', part);
  exception when others then
    null;
  end;

  -- A space that wrote back two days ago or more and still waits for
  -- our answer (migration 234): how many, and the one waiting longest.
  begin
    select jsonb_build_object(
             'n', count(*),
             'name', (array_agg(c.space_name order by coalesce(c.last_in_at, c.stage_at)))[1],
             'at', min(coalesce(c.last_in_at, c.stage_at)))
      into part
      from public.space_contacts c
     where not c.is_test
       and c.stage = 'replied'
       and not public.outreach_aside(c.topic, c.stage)
       and coalesce(c.last_in_at, c.stage_at) <= now() - interval '2 days';
    out := out || jsonb_build_object('replied_wait', part);
  exception when others then
    null;
  end;

  -- The numbers beside the menu's other tools (migration 146): what
  -- is open in each. Each in its own block: a tool whose tables are
  -- not there says nothing, the others still do.
  declare
    n_outreach integer;
    n_review   integer;
    n_feedback integer;
  begin
    begin
      -- Outreach: a space answered and waits for a reply, or a
      -- follow-up you set has come due and nothing has been sent
      -- since that day (the date stays on the contact after sending).
      select count(*) into n_outreach
        from public.space_contacts c
       where not c.is_test
         and (c.stage = 'replied'
          or (c.follow_up_on is not null and c.follow_up_on <= current_date
              and (c.last_out_at is null
                   or c.last_out_at::date < c.follow_up_on)
              and c.stage not in ('claimed', 'verified', 'declined',
                                  'unsubscribed', 'bounced')));
      -- and the spaces that looked at claiming, or made an account,
      -- in the last two weeks (a space with both counts once)
      n_outreach := n_outreach + (
        select count(distinct x.id)
          from unnest(coalesce(look_ids, '{}'::uuid[]) || coalesce(sign_ids, '{}'::uuid[])) as x(id));
    exception when others then
      n_outreach := null;
    end;
    begin
      -- Review submissions: reports waiting to be checked, and photos
      -- waiting for a yes or no.
      select count(*) filter (where s.status = 'pending')
           + count(*) filter (where s.photo_path is not null
                                and s.photo_status = 'pending')
        into n_review
        from public.submissions s;
    exception when others then
      n_review := null;
    end;
    begin
      -- Feedback inbox: messages not marked done.
      select count(*) into n_feedback
        from public.feedback f where f.status = 'new';
    exception when others then
      n_feedback := null;
    end;
    out := out || jsonb_build_object('menu', jsonb_strip_nulls(jsonb_build_object(
      'outreach', n_outreach, 'review', n_review, 'feedback', n_feedback)));
  end;

  return out;
end $$;


-- Links in words in emails: [Owner account](https://...) shows as
-- "Owner account", linked. email_html first links every web address;
-- this then turns "[words](<a ...>address</a>)" into the words, linked.
create or replace function public.email_md_links(p text)
returns text language sql immutable as $$
  select regexp_replace(coalesce(p, ''),
    '\[([^][<>]{1,80})\]\(<a href="([^"]+)" style="color:#E0442E;text-decoration:underline;">[^<]*</a>\)',
    '<a href="\2" style="color:#E0442E;text-decoration:underline;">\1</a>', 'g');
$$;

do $do$
declare
  src text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'email_html';
  if src is null or position('email_md_links' in src) > 0 then
    return;  -- not there, or done already
  end if;
  if position($s$rest := replace(rest, E'\n', '<br>');$s$ in src) = 0
     or position($s$esc := replace(esc, E'\n', '<br>');$s$ in src) = 0
     or position($s$pre := regexp_replace(pre, 'https?://[^[:space:]]+', '', 'g');$s$ in src) = 0 then
    raise exception 'email_html is not as expected; links in words not added';
  end if;
  src := replace(src, $s$rest := replace(rest, E'\n', '<br>');$s$,
                 $s$rest := public.email_md_links(rest);
      rest := replace(rest, E'\n', '<br>');$s$);
  src := replace(src, $s$esc := replace(esc, E'\n', '<br>');$s$,
                 $s$esc := public.email_md_links(esc);
    esc := replace(esc, E'\n', '<br>');$s$);
  src := replace(src, $s$pre := regexp_replace(pre, 'https?://[^[:space:]]+', '', 'g');$s$,
                 $s$pre := regexp_replace(pre, '\[([^]\n]{1,80})\]\(https?://[^)[:space:]]+\)', '\1', 'g');
  pre := regexp_replace(pre, 'https?://[^[:space:]]+', '', 'g');$s$);
  execute src;
end
$do$;

-- A message of ours in a chat, changed or taken back while it is still
-- unsent: not emailed to the owner and not read by them. After that it
-- stays as it is (they have it).
create or replace function public.admin_chat_edit(p_id uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m     public.space_chat_messages%rowtype;
  words text := btrim(coalesce(p_body, ''), E' \t\n\r');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into m from public.space_chat_messages where id = p_id for update;
  if not found then raise exception 'That message is not there any more.'; end if;
  if not m.from_team then raise exception 'Only our own messages can be changed.'; end if;
  if m.emailed_at is not null or m.read_at is not null then
    raise exception 'Too late to change: it has been emailed to them or read already.';
  end if;
  if words = '' then raise exception 'The message is empty. To take it back, press Delete.'; end if;
  if char_length(words) > 4000 then
    raise exception 'That message is a little long: 4,000 characters at most.';
  end if;
  update public.space_chat_messages set body = words where id = p_id;
  return public.admin_chat(m.venue_id, false);
end $$;
revoke all on function public.admin_chat_edit(uuid, text) from public, anon;
grant execute on function public.admin_chat_edit(uuid, text) to authenticated;

create or replace function public.admin_chat_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m public.space_chat_messages%rowtype;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into m from public.space_chat_messages where id = p_id for update;
  if not found then raise exception 'That message is not there any more.'; end if;
  if not m.from_team then raise exception 'Only our own messages can be deleted.'; end if;
  if m.emailed_at is not null or m.read_at is not null then
    raise exception 'Too late to delete: it has been emailed to them or read already.';
  end if;
  delete from public.space_chat_messages where id = p_id;
  return public.admin_chat(m.venue_id, false);
end $$;
revoke all on function public.admin_chat_delete(uuid) from public, anon;
grant execute on function public.admin_chat_delete(uuid) to authenticated;
