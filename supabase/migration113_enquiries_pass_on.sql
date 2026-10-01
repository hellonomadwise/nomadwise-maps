-- ============================================================
-- Migration 113: every enquiry reaches the space.
-- (Applied automatically by the build; nothing to paste.)
--
-- Until now the Send an enquiry pop-up on free pages (the Webflow
-- "Research Form") only emailed hello@nomadwise.io, and the space never
-- heard about it. Now:
--   * The pop-up stays exactly as it is on nomadwise.io. The ten-minute
--     job reads its submissions from Webflow and files each one here,
--     next to the requests from the Verified form (?enquire=).
--   * Verified page with an enquiry address: sent straight to the
--     space, as before.
--   * Every other page (not claimed yet, or claimed on Free): the
--     enquiry waits in "Enquiries to pass on" in the control centre and
--     the phone is pinged. The space's own email, found on its website,
--     is suggested. Pass on sends it to the space (reply goes straight
--     to the nomad), with a free claim link for an unclaimed page or a
--     line about Verified for a Free one, and tells the nomad it went.
--   * Already handled / Can't reach close it; Can't reach can send the
--     nomad the space's website instead.
-- Submissions from before this went live are kept as history (they
-- count towards a space's enquiries) without anything to do.
-- ============================================================

-- 1. The enquiries table learns the new routes.
alter table public.enquiries alter column venue_id drop not null;
alter table public.enquiries
  add column if not exists webflow_submission_id text,
  add column if not exists listing_text   text,
  add column if not exists marketing_ok   boolean,
  add column if not exists passed_to      text,
  add column if not exists passed_at      timestamptz,
  add column if not exists handled_note   text,
  add column if not exists nomad_emailed_at timestamptz;

create unique index if not exists idx_enquiries_webflow_submission
  on public.enquiries(webflow_submission_id) where webflow_submission_id is not null;

do $$
declare c record;
begin
  for c in
    select con.conname from pg_constraint con
     where con.conrelid = 'public.enquiries'::regclass
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%status%'
  loop
    execute format('alter table public.enquiries drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.enquiries
  add constraint enquiries_status_check
  check (status in ('new', 'sent', 'failed', 'waiting', 'passed', 'closed'));

-- Emails found on a space's own website, newest guess first, for the
-- Pass on box. Filled by the ten-minute job; a founder's choice is
-- put first when they pass something on.
alter table public.venues
  add column if not exists contact_emails text[],
  add column if not exists contact_checked_at timestamptz;

-- 2. The rate guard is for the public form; the pop-up's submissions
-- were already checked by Webflow and may arrive in a batch, so the
-- import (and only the import) skips it. The public form may only
-- file a fresh request for a known space, nothing else.
drop policy if exists "enquiries insert public" on public.enquiries;
create policy "enquiries insert public" on public.enquiries
  for insert to anon, authenticated
  with check (status = 'new' and sent_at is null and to_email is null
              and venue_id is not null
              and coalesce(source, 'nomadwise') <> 'webflow_popup'
              and webflow_submission_id is null and listing_text is null
              and passed_to is null and passed_at is null
              and handled_note is null and nomad_emailed_at is null);

create or replace function public.enquiry_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('nomadmaps.enquiry_import', true) = '1' then
    return new;           -- filed by import_webflow_enquiry()
  end if;
  if (select count(*) from public.enquiries
       where email = new.email and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Too many requests from this address; try again later.';
  end if;
  if new.venue_id is not null and (select count(*) from public.enquiries
       where venue_id = new.venue_id and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'This listing has had a lot of requests in the last hour; try again later.';
  end if;
  return new;
end $$;

-- 3. Where a new enquiry goes. Straight to the space only when it is
-- Verified and has an enquiry address; otherwise it waits for us.
create or replace function public.enquiry_goes_direct(p_venue uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select v.listing_tier = 'verified'
           and coalesce(trim(v.listing_enquiry_email), '') like '%@%'
      from public.venues v where v.id = p_venue), false);
$$;
revoke all on function public.enquiry_goes_direct(uuid) from public, anon, authenticated;

create or replace function public.enquiry_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  vname text;
begin
  if new.status <> 'new' then
    return new;           -- history, or filed by hand
  end if;
  select name into vname from public.venues where id = new.venue_id;
  if new.venue_id is not null and public.enquiry_goes_direct(new.venue_id) then
    perform public.send_enquiry(new.id);
    perform public.notify_phone(
      'Enquiry sent to ' || coalesce(vname, 'a Verified space'),
      new.name || ' wrote: ' || left(coalesce(new.message, ''), 120),
      'envelope');
  else
    update public.enquiries set status = 'waiting' where id = new.id;
    perform public.notify_phone(
      'Enquiry to pass on: ' || coalesce(vname, new.listing_text, 'a space'),
      new.name || ' wrote: ' || left(coalesce(new.message, ''), 120)
        || E'\nOpen the control centre to pass it on.',
      'envelope');
  end if;
  return new;
exception when others then
  return new;
end $$;

-- 4. The pop-up's "Listing" field reads "Name, Region, Location".
-- Names can contain commas, so the last two parts are the place.
create or replace function public.match_listing(p_listing text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
  parts text[];
  nm    text;
  loc   text := '';
  hit   uuid;
  n     int;
begin
  parts := string_to_array(coalesce(trim(p_listing), ''), ', ');
  n := coalesce(array_length(parts, 1), 0);
  if n = 0 then return null; end if;
  if n >= 3 then
    nm := array_to_string(parts[1:n-2], ', ');
    loc := lower(parts[n-1] || ' ' || parts[n]);
  elsif n = 2 then
    nm := parts[1];
    loc := lower(parts[2]);
  else
    nm := parts[1];
  end if;

  select v.id into hit
    from public.venues v
   where lower(trim(v.name)) = lower(trim(nm))
     and coalesce(v.website_status, '') <> 'retired'
   order by (loc <> '' and (position(lower(coalesce(nullif(trim(v.city), ''), '#')) in loc) > 0
                            or position(lower(coalesce(nullif(trim(v.neighbourhood), ''), '#')) in loc) > 0)) desc,
            (v.webflow_cms_id is not null) desc,
            v.created_at
   limit 1;
  return hit;
end $$;
revoke all on function public.match_listing(text) from public, anon, authenticated;

insert into public.sync_settings (key, value)
values ('enquiry_import_since', jsonb_build_object('since', now()))
on conflict (key) do nothing;

-- 5. Filing one pop-up submission (the ten-minute job, service role).
-- Returns 'known', 'invalid', 'history' or the new status.
create or replace function public.import_webflow_enquiry(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare
  sid   text := nullif(trim(coalesce(p->>'id', '')), '');
  em    text := lower(trim(coalesce(p->>'email', '')));
  nm    text := left(nullif(trim(coalesce(p->>'name', '')), ''), 120);
  at_   timestamptz := coalesce(nullif(p->>'submitted_at', '')::timestamptz, now());
  vid   uuid;
  old   boolean;
  st    text;
  newid uuid;
begin
  if sid is null then return 'invalid'; end if;
  if exists (select 1 from public.enquiries where webflow_submission_id = sid) then
    return 'known';
  end if;
  if position('@' in em) < 2 or char_length(em) > 200 then
    return 'invalid';
  end if;
  vid := public.match_listing(p->>'listing');
  -- Before this went live the Webflow email was the only copy, so
  -- those are kept as history with nothing left to do.
  old := at_ < coalesce((select (value->>'since')::timestamptz from public.sync_settings
                          where key = 'enquiry_import_since'), now());
  perform set_config('nomadmaps.enquiry_import', '1', true);

  insert into public.enquiries (
    venue_id, name, email, phone, want, message, source, status,
    webflow_submission_id, listing_text, marketing_ok, created_at, handled_note)
  values (
    vid, coalesce(nm, 'Someone'), em,
    left(nullif(trim(coalesce(p->>'phone', '')), ''), 60),
    'other',
    left(nullif(trim(coalesce(p->>'message', '')), ''), 3000),
    'webflow_popup',
    case when old then 'closed' else 'new' end,
    sid, left(p->>'listing', 300),
    lower(coalesce(p->>'marketing', '')) in ('true', 'yes', 'on'),
    at_,
    case when old then 'From before the pass-on list (Webflow email only).' end)
  returning id into newid;

  perform set_config('nomadmaps.enquiry_import', '', true);
  select status into st from public.enquiries where id = newid;
  return case when old then 'history' else st end;
end $$;
revoke all on function public.import_webflow_enquiry(jsonb) from public, anon, authenticated;
grant execute on function public.import_webflow_enquiry(jsonb) to service_role;

-- 6. One email through Postmark with a reply-to, logged with the
-- owner emails. Raises if it could not be handed to Postmark.
create or replace function public.send_enquiry_mail(
  p_to text, p_reply_to text, p_subject text, p_text text, p_kind text,
  p_ref text, p_venue uuid, p_cc text default 'hello@nomadwise.io')
returns void language plpgsql security definer set search_path = public as $$
declare
  token text;
  req   bigint;
  payload jsonb;
begin
  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if token is null or token = '' then
    raise exception 'No Postmark token in Vault yet (postmark_server_token).';
  end if;
  payload := jsonb_build_object(
    'From', 'Jonathan at Nomadwise <hello@nomadwise.io>',
    'To', p_to,
    'ReplyTo', coalesce(nullif(p_reply_to, ''), 'hello@nomadwise.io'),
    'Subject', p_subject,
    'TextBody', p_text,
    'HtmlBody', public.owner_email_html(p_text),
    'MessageStream', 'outbound',
    'Tag', p_kind);
  if coalesce(p_cc, '') <> '' and lower(p_cc) <> lower(p_to) then
    payload := payload || jsonb_build_object('Cc', p_cc);
  end if;
  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := payload,
    headers := jsonb_build_object(
      'X-Postmark-Server-Token', token,
      'Accept', 'application/json',
      'Content-Type', 'application/json'))
  into req;
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, venue_id)
    values (p_kind, p_to, p_subject, p_ref, 'sent', req::text, p_text, p_venue);
  exception when others then null; end;
end $$;
revoke all on function public.send_enquiry_mail(text, text, text, text, text, text, uuid, text)
  from public, anon, authenticated;

-- 7. Pass on: to the space, and a line to the nomad.
create or replace function public.admin_enquiry_pass_on(
  p_id uuid, p_to text, p_tell_nomad boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  dest  text := lower(trim(coalesce(p_to, '')));
  page  text;
  pitch text;
  body  text;
  kind  text;
  first text;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  if dest !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That does not look like an email address.';
  end if;
  select * into e from public.enquiries where id = p_id for update;
  if not found then raise exception 'Enquiry not found.'; end if;
  if e.status <> 'waiting' then
    raise exception 'This enquiry has already been dealt with.';
  end if;
  if e.venue_id is null then
    raise exception 'Choose the space first.';
  end if;
  select * into v from public.venues where id = e.venue_id;

  page := case when v.webflow_slug is not null
               then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  kind := public.space_kind(v.type);
  first := nullif(nullif(split_part(trim(e.name), ' ', 1), ''), 'Someone');

  if v.listing_tier = 'verified' then
    pitch := 'Your page is Verified, but it has no enquiry address yet. Add one in '
          || 'your Owner account and enquiries like this will reach you directly: '
          || 'https://nomadmaps.io/?owner';
  elsif coalesce(trim(v.listing_owner_email), '') = '' then
    pitch := 'We listed ' || v.name || ' using public information. You can claim the '
          || 'page for free to add your own photos, prices and opening hours, and to '
          || 'keep your details up to date: https://nomadmaps.io/?claim='
          || coalesce(v.webflow_slug, replace(v.name, ' ', '%20'));
  else
    pitch := 'You are on the Free plan, so enquiries come to us first and we pass '
          || 'them on. With Verified they come straight to your inbox, together with '
          || 'the Verified badge and a place above the free listings in '
          || coalesce(nullif(v.city, ''), 'your city') || ': '
          || 'https://nomadmaps.io/?owner&billing';
  end if;

  body := 'Hi ' || v.name || ' team,' || E'\n\n'
       || coalesce(first, 'A remote worker') || ' sent this enquiry through your '
       || case when page is not null then 'page' else 'listing' end
       || ' on nomadwise.io, a directory of coworking spaces and cafes for remote workers'
       || coalesce(': ' || page, '.') || E'\n\n'
       || 'From: ' || e.name || ' <' || e.email || '>' || E'\n'
       || coalesce('Phone: ' || nullif(e.phone, '') || E'\n', '')
       || case e.want when 'day_pass' then 'About: a day pass' || E'\n'
                      when 'desk_month' then 'About: a desk for a month or longer' || E'\n'
                      when 'event' then 'About: a meeting or event' || E'\n'
                      else '' end
       || coalesce('Dates: ' || nullif(e.dates, '') || E'\n', '')
       || coalesce('People: ' || e.people::text || E'\n', '')
       || 'Sent: ' || to_char(e.created_at at time zone 'utc', 'DD Mon YYYY') || E'\n\n'
       || coalesce(e.message, '(no message)') || E'\n\n'
       || 'Reply to this email to answer ' || coalesce(first, 'them') || ' directly.' || E'\n\n'
       || pitch || E'\n\n'
       || 'Thanks,' || E'\n' || 'Jonathan' || E'\n' || 'Nomadwise';

  perform public.send_enquiry_mail(
    dest, e.email,
    'Enquiry for ' || v.name || ' from nomadwise.io',
    body, 'enquiry_passed', e.id::text, v.id);

  update public.enquiries
     set status = 'passed', passed_to = dest, passed_at = now(),
         to_email = dest, sent_at = now(), send_error = null
   where id = p_id;

  -- Remember the address for the next one.
  update public.venues
     set contact_emails = array_prepend(dest, array_remove(coalesce(contact_emails, '{}'), dest))
   where id = v.id;

  if p_tell_nomad then
    perform public.send_enquiry_mail(
      e.email, 'hello@nomadwise.io',
      'Your enquiry for ' || v.name,
      'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
      || 'Thanks for your enquiry about ' || v.name || ' on nomadwise.io. We have '
      || 'passed it on to the ' || kind || ', and they will reply to you directly at '
      || 'this email address.' || E'\n\n'
      || coalesce(case when coalesce(v.website, '') <> ''
                       then 'If you would like to contact them yourself as well, their '
                            || 'website is ' || v.website || E'\n\n' end, '')
      || 'Enjoy your visit,' || E'\n' || 'Jonathan' || E'\n' || 'Nomadwise',
      'enquiry_passed_nomad', e.id::text, v.id, null);
    update public.enquiries set nomad_emailed_at = now() where id = p_id;
  end if;

  return jsonb_build_object('status', 'passed', 'to', dest);
end $$;
revoke all on function public.admin_enquiry_pass_on(uuid, text, boolean) from public, anon;
grant execute on function public.admin_enquiry_pass_on(uuid, text, boolean) to authenticated;

-- 8. Close without passing on. 'handled' (done by hand), 'unreachable'
-- (no way to reach the space; the nomad can be sent its website) or
-- 'spam'.
create or replace function public.admin_enquiry_close(
  p_id uuid, p_reason text, p_tell_nomad boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  first text;
  ways  text;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  if p_reason not in ('handled', 'unreachable', 'spam') then
    raise exception 'Unknown reason.';
  end if;
  select * into e from public.enquiries where id = p_id for update;
  if not found then raise exception 'Enquiry not found.'; end if;
  if e.status <> 'waiting' then
    raise exception 'This enquiry has already been dealt with.';
  end if;

  update public.enquiries
     set status = 'closed',
         handled_note = case p_reason
                          when 'handled' then 'Handled by hand.'
                          when 'unreachable' then 'No way to reach the space.'
                          else 'Spam.' end
   where id = p_id;

  if p_reason = 'unreachable' and p_tell_nomad and e.venue_id is not null then
    select * into v from public.venues where id = e.venue_id;
    first := nullif(nullif(split_part(trim(e.name), ' ', 1), ''), 'Someone');
    ways := concat_ws(E'\n',
              case when coalesce(v.website, '') <> '' then 'Website: ' || v.website end,
              case when coalesce(v.instagram, '') <> '' then 'Instagram: ' || v.instagram end,
              case when v.google_place_id is not null
                   then 'Google Maps: https://www.google.com/maps/place/?q=place_id:'
                        || v.google_place_id end);
    perform public.send_enquiry_mail(
      e.email, 'hello@nomadwise.io',
      'Your enquiry for ' || v.name,
      'Hi ' || coalesce(nullif(first, ''), 'there') || ',' || E'\n\n'
      || 'Thanks for your enquiry about ' || v.name || ' on nomadwise.io. We could '
      || 'not find a way to pass it on to them, so the quickest way to get an answer '
      || 'is to contact them directly'
      || case when ways <> '' then ':' || E'\n\n' || ways else '.' end || E'\n\n'
      || 'Sorry we could not do more this time.' || E'\n\n'
      || 'Jonathan' || E'\n' || 'Nomadwise',
      'enquiry_unreachable_nomad', e.id::text, v.id, null);
    update public.enquiries set nomad_emailed_at = now() where id = p_id;
  end if;
  return jsonb_build_object('status', 'closed');
end $$;
revoke all on function public.admin_enquiry_close(uuid, text, boolean) from public, anon;
grant execute on function public.admin_enquiry_close(uuid, text, boolean) to authenticated;

-- 9. A submission whose listing could not be matched: choose the space.
create or replace function public.admin_enquiry_attach(p_id uuid, p_venue uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  update public.enquiries set venue_id = p_venue where id = p_id;
  return jsonb_build_object('venue_id', p_venue);
end $$;
revoke all on function public.admin_enquiry_attach(uuid, uuid) from public, anon;
grant execute on function public.admin_enquiry_attach(uuid, uuid) to authenticated;

-- 10. What the control centre shows: the waiting ones with the space's
-- details and suggested addresses, plus counts.
create or replace function public.admin_enquiries_to_pass_on()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return jsonb_build_object(
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'name', e.name, 'email', e.email, 'phone', e.phone,
               'message', e.message, 'dates', e.dates, 'created_at', e.created_at,
               'listing_text', e.listing_text, 'source', e.source,
               'venue_id', v.id, 'venue_name', v.name, 'city', v.city,
               'slug', v.webflow_slug, 'website', v.website, 'instagram', v.instagram,
               'tier', coalesce(v.listing_tier, 'free'),
               'owner_email', v.listing_owner_email,
               'contact_emails', coalesce(to_jsonb(v.contact_emails), '[]'::jsonb),
               'contact_checked', v.contact_checked_at is not null,
               'earlier', (select count(*) from public.enquiries x
                            where x.venue_id = e.venue_id and x.id <> e.id))
             order by e.created_at)
        from public.enquiries e
        left join public.venues v on v.id = e.venue_id
       where e.status = 'waiting'), '[]'::jsonb),
    'passed_30d', (select count(*) from public.enquiries
                    where status = 'passed' and passed_at > now() - interval '30 days'),
    'direct_30d', (select count(*) from public.enquiries
                    where status = 'sent' and sent_at > now() - interval '30 days'),
    'import', (select value from public.sync_settings where key = 'enquiry_import'));
end $$;
revoke all on function public.admin_enquiries_to_pass_on() from public, anon;
grant execute on function public.admin_enquiries_to_pass_on() to authenticated;
