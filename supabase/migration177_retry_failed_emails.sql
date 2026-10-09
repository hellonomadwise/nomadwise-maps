-- 177: an email that did not get through on the way is sent again.
--
-- Open since 7 Oct 2026: an email to an owner (claims, chat, owner
-- account, sign-in reminders) goes to Postmark once. When Postmark
-- could not be reached, timed out, was busy (429) or had a fault of
-- its own (5xx), the email was simply lost; the Email log showed it,
-- nobody resent it.
--
-- Now each email keeps exactly what was sent (payload), and every
-- 20 minutes such a failed send is tried again as it was, up to three
-- tries in all, within six hours (pg_net keeps Postmark's answers for
-- about that long). A refusal that would only happen again (an
-- unknown or inactive address, 4xx other than 429) is not retried:
-- it stays in the Email log as refused.
-- Outreach emails (their own table) are not part of this.
-- The two senders are those of migrations 101 and 162, with the
-- payload kept. Safe to apply twice.

alter table public.owner_emails
  add column if not exists payload jsonb,
  add column if not exists attempts integer not null default 1,
  add column if not exists last_try_at timestamptz;

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

  -- The button's address also goes into the plain text, so a reader
  -- without HTML still has somewhere to go.
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

create or replace function public.send_owner_email_reply_to(
  p_to text, p_subject text, p_text text, p_kind text, p_ref text,
  p_cta_label text, p_cta_url text, p_reply_to text)
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

  -- kept with the row, so a send that failed on the way can be
  -- tried again as it was (migration 177)
  pl := jsonb_build_object(
      'From', 'Jonathan at Nomadwise <hello@nomadwise.io>',
      'To', dest,
      'Bcc', 'hello@nomadwise.io',
      'ReplyTo', coalesce(nullif(btrim(coalesce(p_reply_to, '')), ''), 'hello@nomadwise.io'),
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

-- Every 20 minutes: the sends that failed on the way, tried again.
create or replace function public.owner_emails_retry()
returns integer language plpgsql security definer set search_path = public as $$
declare
  e     record;
  token text;
  req   bigint;
  n     integer := 0;
begin
  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if coalesce(token, '') = '' then return 0; end if;
  for e in
    select o.id, o.payload
      from public.owner_emails o
      join net._http_response r
        on o.provider_req ~ '^[0-9]+$' and r.id = o.provider_req::bigint
     where o.status = 'sent'
       and o.payload is not null
       and o.attempts < 3
       and o.created_at > now() - interval '6 hours'
       and coalesce(o.last_try_at, o.created_at) < now() - interval '15 minutes'
       and (coalesce(r.timed_out, false)
            or r.status_code is null
            or r.status_code = 429
            or r.status_code >= 500)
     order by o.created_at
     limit 20
  loop
    select net.http_post(
      url := 'https://api.postmarkapp.com/email',
      body := e.payload,
      headers := jsonb_build_object(
        'X-Postmark-Server-Token', token,
        'Accept', 'application/json',
        'Content-Type', 'application/json'),
      timeout_milliseconds := 15000)
    into req;
    update public.owner_emails
       set provider_req = req::text,
           attempts = attempts + 1,
           last_try_at = now()
     where id = e.id;
    n := n + 1;
  end loop;
  return n;
exception when others then
  raise warning 'owner_emails_retry: %', sqlerrm;
  return n;
end $$;
revoke all on function public.owner_emails_retry() from public, anon, authenticated;
grant execute on function public.owner_emails_retry() to service_role;

do $$
begin
  perform cron.unschedule('owner-emails-retry');
exception when others then null;
end $$;
do $$
begin
  perform cron.schedule('owner-emails-retry', '*/20 * * * *',
    'select public.owner_emails_retry()');
exception when others then
  raise warning 'owner-emails-retry not scheduled: %', sqlerrm;
end $$;
