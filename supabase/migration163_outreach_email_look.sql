-- Migration 163: Outreach emails to spaces that have claimed, in the
-- same look as our other emails.
--
-- Jonathan, 7 Oct 2026, with two emails side by side in his inbox: the
-- chat email in its card under "nomadwise FOR SPACES", and an Outreach
-- email ("Your Owner account for ...") as bare text. "I want it to be
-- the same as how the nomadwise for spaces email is styled."
--
-- Outreach emails sent from here (through Postmark) went out as text
-- only, since migration 121. An email to a space that has claimed
-- (stage claimed or verified) now carries the designed version too,
-- made by the same function as every other email to a space
-- (owner_email_html, migration 91), so one change to the look changes
-- all of them. The words are untouched, and the plain text still
-- travels with it for mail programs that prefer it.
--
-- Everybody else gets the email as before, as plain text: a first
-- email, a follow-up to somebody who has not answered, an answer to
-- somebody who wrote to us. A designed email to a space that does not
-- know us is more likely to be filed under Promotions than a plain
-- one, and Jonathan chose the inbox: "if they are more likely to be
-- filed under Promotions, then lets not do the branded look for first
-- contact emails".
--
-- One difference from the plain text: the last line, "If you would
-- rather not hear from us again: <long address>", reads "..., unsubscribe
-- here." with the address behind the two words, as the small grey line
-- at the foot of the card.
--
-- Emails sent from the founder's own inbox (the other Outreach route)
-- are written in that mail program and are not changed by this.

-- The designed version of one Outreach email. Null when it cannot be
-- made, and the email then goes out as plain text, as before.
create or replace function public.outreach_email_html(p_body text)
returns text language plpgsql immutable as $$
declare
  main text := coalesce(p_body, '');
  cut  text;
  url  text;
  html text;
  mark constant text := 'NWUNSUBSCRIBEMARK';
begin
  if btrim(main) = '' then return null; end if;
  url := substring(main from '(https://nomadmaps\.io/\?unsubscribe=[0-9A-Za-z_-]+)\s*$');
  -- the paragraph that carries the address: the last one
  cut := regexp_replace(main,
           '\n\n[^\n]*https://nomadmaps\.io/\?unsubscribe=[0-9A-Za-z_-]+\s*$', '');
  if url is null or cut = main or btrim(cut) = '' then
    -- no such line at the end (somebody wrote their own): as it is
    return public.owner_email_html(main, null, null);
  end if;
  html := public.owner_email_html(
            cut || E'\n\n' || 'If you would rather not hear from us again, ' || mark || '.',
            null, null);
  return replace(html, mark,
           '<a href="' || url || '" style="color:#5C6773;text-decoration:underline;">unsubscribe here</a>');
exception when others then
  return null;
end $$;
revoke all on function public.outreach_email_html(text) from public, anon, authenticated;

-- Send (as in migration 121), with the designed version added for a
-- space that has claimed.
create or replace function public.admin_outreach_send(
  p_id uuid, p_subject text, p_body text, p_template text default null, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c       public.space_contacts%rowtype;
  t       public.outreach_templates%rowtype;
  token   text;
  payload jsonb;
  req     bigint;
  today_n integer;
  who     text;
  body    text := p_body;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id for update;
  if not found then raise exception 'Contact not found.'; end if;
  if c.email is null then raise exception 'This contact has no email address.'; end if;
  if c.unsubscribed_at is not null then
    raise exception 'They asked us not to write again.';
  end if;
  if not p_force and c.last_out_at is not null and c.last_out_at > now() - interval '30 days' then
    raise exception 'We wrote to them on % already. Tick "send anyway" to send another.',
      to_char(c.last_out_at, 'DD Mon');
  end if;
  select count(*) into today_n from public.outreach_messages
   where direction = 'out' and send_error is null and at >= date_trunc('day', now());
  if today_n >= 40 then
    raise exception 'That is 40 outreach emails today, which is the daily limit. Tomorrow.';
  end if;
  if nullif(trim(p_subject), '') is null or nullif(trim(p_body), '') is null then
    raise exception 'Subject and body are both needed.';
  end if;
  if position('{' in body) > 0 and body ~ '\{[a-z_]+\}' then
    raise exception 'The email still has a placeholder in it: %', substring(body from '\{[a-z_]+\}');
  end if;

  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if coalesce(token, '') = '' then
    raise exception 'No Postmark token in the Vault (postmark_server_token).';
  end if;
  if p_template is not null then
    select * into t from public.outreach_templates where key = p_template;
  end if;
  who := coalesce((select email from auth.users where id = auth.uid()), 'founder');

  -- Every outreach email can be stopped with one click.
  if position('?unsubscribe=' in body) = 0 then
    body := body || E'\n\nIf you would rather not hear from us again: https://nomadmaps.io/?unsubscribe=' || c.unsub_token;
  end if;

  payload := jsonb_build_object(
      'From', 'Jonathan at Nomadwise <hello@nomadwise.io>',
      'To', c.email,
      'ReplyTo', 'hello@nomadwise.io',
      'Bcc', 'hello@nomadwise.io',
      'Subject', trim(p_subject),
      'TextBody', body,
      -- the card only for a space that has claimed; plain for the rest
      'HtmlBody', case when c.stage in ('claimed', 'verified')
                       then public.outreach_email_html(body) end,
      'MessageStream', coalesce(t.stream, 'outbound'),
      'Tag', 'outreach');
  -- (no designed version: the plain text goes by itself)
  payload := jsonb_strip_nulls(payload);
  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := payload,
    headers := jsonb_build_object(
      'X-Postmark-Server-Token', token,
      'Accept', 'application/json',
      'Content-Type', 'application/json'))
  into req;

  insert into public.outreach_messages (contact_id, direction, template_key, subject, body, postmark_id, sent_by)
  values (c.id, 'out', p_template, trim(p_subject), body, req::text, who);
  update public.space_contacts
     set last_out_at = now(),
         stage = case when stage in ('new', 'contacted', 'not_now', 'replied') then 'contacted' else stage end
   where id = c.id;
  return jsonb_build_object('ok', true, 'to', c.email);
end $$;
revoke all on function public.admin_outreach_send(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.admin_outreach_send(uuid, text, text, text, boolean) to authenticated;
