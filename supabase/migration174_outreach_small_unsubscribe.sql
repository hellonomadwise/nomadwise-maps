-- 174: the unsubscribe line in a plain Outreach email: small, grey,
-- two words.
--
-- Jonathan, 8 Oct 2026, on "Any questions about claiming..." to
-- Workland Fahle: "In this email the unsubscribe link should be styled
-- and smaller and a shorter link". A first email (or any email to a
-- space that has not claimed) went out as plain text only (migration
-- 163, so it lands in the inbox and not under Promotions), and the
-- last line was the whole address:
--   "If you would rather not hear from us again: https://nomadmaps.io/?unsubscribe=25dabc..."
--
-- Now those emails carry an HTML version that still looks like a
-- plain email (no logo, no card, no pictures, no buttons: ordinary
-- text, links underlined), with the last line in small grey type:
--   "If you would rather not hear from us again, unsubscribe here."
-- and the address behind "unsubscribe here". The plain text travels
-- with it for mail programs that show only text. Emails to a space
-- that has claimed keep the designed card (migration 163).
-- Safe to apply twice.

-- Plain text as a plain-looking HTML email. Null when it cannot be
-- made; the email then goes out as plain text, as before.
create or replace function public.outreach_plain_html(p_body text)
returns text language plpgsql immutable as $$
declare
  main  text := coalesce(p_body, '');
  url   text;
  cut   text;
  paras text[];
  p     text;
  html  text := '';
begin
  if btrim(main) = '' then return null; end if;
  url := substring(main from '(https://nomadmaps\.io/\?unsubscribe=[0-9A-Za-z_-]+)\s*$');
  if url is not null then
    -- the paragraph that carries the address: the last one
    cut := regexp_replace(main,
             '\n\n[^\n]*https://nomadmaps\.io/\?unsubscribe=[0-9A-Za-z_-]+\s*$', '');
    if cut = main then url := null; else main := cut; end if;
  end if;

  paras := regexp_split_to_array(btrim(replace(main, E'\r', '')), E'\n\\s*\n');
  foreach p in array paras loop
    if btrim(p) = '' then continue; end if;
    -- escaped, links made clickable, single line breaks kept
    p := replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    p := regexp_replace(p, '(https?://[^\s<]+[^\s<.,;:!?)])',
                        '<a href="\1" style="color:#1A56DB;">\1</a>', 'g');
    p := regexp_replace(p, '(^|[\s(])(www\.[^\s<]+[^\s<.,;:!?)])',
                        '\1<a href="https://\2" style="color:#1A56DB;">\2</a>', 'g');
    p := replace(btrim(p), E'\n', '<br>');
    html := html || '<p style="margin:0 0 14px 0;">' || p || '</p>';
  end loop;

  if url is not null then
    html := html
      || '<p style="margin:22px 0 0 0;font-size:12px;line-height:1.5;color:#8A94A0;">'
      || 'If you would rather not hear from us again, '
      || '<a href="' || url || '" style="color:#8A94A0;text-decoration:underline;">unsubscribe here</a>.'
      || '</p>';
  end if;

  return '<!DOCTYPE html><html><head><meta charset="utf-8">'
      || '<meta name="viewport" content="width=device-width,initial-scale=1"></head>'
      || '<body style="margin:0;padding:0;">'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:1.55;color:#1F2933;max-width:600px;padding:8px 4px;">'
      || html || '</div></body></html>';
exception when others then
  return null;
end $$;
revoke all on function public.outreach_plain_html(text) from public, anon, authenticated;

-- Send, as in migration 163, with that HTML version for the emails
-- that went as plain text.
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
      -- the card for a space that has claimed; for the rest the same
      -- plain-looking email, with a small unsubscribe line (migration 174)
      'HtmlBody', case when c.stage in ('claimed', 'verified')
                       then public.outreach_email_html(body)
                       else public.outreach_plain_html(body) end,
      'MessageStream', coalesce(t.stream, 'outbound'),
      'Tag', 'outreach');
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
