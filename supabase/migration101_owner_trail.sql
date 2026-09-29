-- ============================================================
-- Migration 101: the back and forth with each owner, kept and shown.
-- (Applied automatically by the build; nothing to paste.)
--
-- The email log only kept each email's subject, and an owner's draft
-- is one row that changes in place, so "sent back, fixed, sent again,
-- put on" left no trail. Now:
--   owner_emails      also keeps the full text, the button's link and
--                     the space it is about (earlier rows get the space
--                     where it can be worked out; their text was not
--                     kept)
--   owner_draft_events one row each time an owner submits changes, we
--                     send them back (with the note) or put them on,
--                     with what was submitted
--   admin_email_log   returns the text and the space too
--   admin_space_trail everything for one space, newest first: claims,
--                     approval, submissions, notes, changes put on,
--                     visitors' suggested updates and every email
-- ============================================================

alter table public.owner_emails
  add column if not exists body     text,
  add column if not exists cta_url  text,
  add column if not exists venue_id uuid;
create index if not exists idx_owner_emails_venue on public.owner_emails(venue_id, created_at desc);

-- The space an email's ref points at: a claim, a draft or the venue.
create or replace function public.owner_email_venue(p_ref text)
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(
    (select c.venue_id from public.listing_claims c where c.id::text = p_ref),
    (select d.venue_id from public.owner_drafts d where d.id::text = p_ref),
    (select v.id from public.venues v where v.id::text = p_ref));
$$;

update public.owner_emails e
   set venue_id = public.owner_email_venue(e.ref)
 where e.venue_id is null and e.ref is not null;

create or replace function public.send_owner_email(
  p_to text, p_subject text, p_text text, p_kind text, p_ref text default null,
  p_cta_label text default null, p_cta_url text default null)
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

  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := jsonb_build_object(
      'From', 'Jonathan at Nomadwise <hello@nomadwise.io>',
      'To', dest,
      'Bcc', 'hello@nomadwise.io',
      'ReplyTo', 'hello@nomadwise.io',
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

-- Every submit, send-back and put-on of an owner's changes.
create table if not exists public.owner_draft_events (
  id          uuid primary key default gen_random_uuid(),
  draft_id    uuid,
  venue_id    uuid,
  owner_email text,
  status      text not null,
  note        text,
  draft       jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists idx_owner_draft_events_venue on public.owner_draft_events(venue_id, created_at desc);
alter table public.owner_draft_events enable row level security;
drop policy if exists "owner_draft_events admin" on public.owner_draft_events;
create policy "owner_draft_events admin" on public.owner_draft_events
  for select to authenticated using (public.is_admin());

create or replace function public.log_owner_draft_event()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('submitted', 'declined', 'applied')
     and (tg_op = 'INSERT' or old.status is distinct from new.status
          or (new.status = 'submitted' and old.submitted_at is distinct from new.submitted_at)) then
    insert into public.owner_draft_events (draft_id, venue_id, owner_email, status, note, draft)
    values (new.id, new.venue_id, new.owner_email, new.status,
            case when new.status = 'declined' then new.review_note end,
            case when new.status = 'submitted' then new.draft end);
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists log_owner_draft_event on public.owner_drafts;
create trigger log_owner_draft_event
  after insert or update on public.owner_drafts
  for each row execute function public.log_owner_draft_event();

-- What happened before today, from what the drafts still hold.
insert into public.owner_draft_events (draft_id, venue_id, owner_email, status, note, draft, created_at)
select d.id, d.venue_id, d.owner_email, 'submitted', null, d.draft, d.submitted_at
  from public.owner_drafts d
 where d.submitted_at is not null
   and not exists (select 1 from public.owner_draft_events x where x.draft_id = d.id);
insert into public.owner_draft_events (draft_id, venue_id, owner_email, status, note, draft, created_at)
select d.id, d.venue_id, d.owner_email, d.status,
       case when d.status = 'declined' then d.review_note end, null, d.reviewed_at
  from public.owner_drafts d
 where d.status in ('declined', 'applied') and d.reviewed_at is not null
   and not exists (select 1 from public.owner_draft_events x
                    where x.draft_id = d.id and x.status = d.status);

-- The email log, with the text and the space.
drop function if exists public.admin_email_log(integer);
create or replace function public.admin_email_log(p_limit integer default 50)
returns table (
  id uuid, kind text, to_email text, subject text, ref text,
  status text, error text, created_at timestamptz,
  http_status integer, http_body text,
  body text, cta_url text, venue_id uuid, venue_name text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return query
    select e.id, e.kind, e.to_email, e.subject, e.ref, e.status, e.error,
           e.created_at,
           r.status_code::integer,
           left(coalesce(r.content::text, r.error_msg, ''), 400),
           e.body, e.cta_url, e.venue_id, v.name
      from public.owner_emails e
      left join public.venues v on v.id = e.venue_id
      left join net._http_response r
        on e.provider_req ~ '^[0-9]+$'
       and r.id = e.provider_req::bigint
     order by e.created_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end $$;
grant execute on function public.admin_email_log(integer) to authenticated;

-- Everything for one space, newest first.
create or replace function public.admin_space_trail(p_venue uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select coalesce(jsonb_agg(t.ev order by t.at desc), '[]'::jsonb) into out
    from (
      select c.created_at as at, jsonb_build_object(
               'at', c.created_at, 'kind', 'claim',
               'title', 'Claimed (' || coalesce(c.plan, 'verified') || ')',
               'detail', trim(c.owner_name || coalesce(' (' || nullif(c.owner_role, '') || ')', '')
                              || ', ' || c.owner_email),
               'text', nullif(c.note, '')) as ev
        from public.listing_claims c where c.venue_id = p_venue
      union all
      select c.approved_at, jsonb_build_object(
               'at', c.approved_at, 'kind', 'approved',
               'title', 'Claim approved', 'detail', c.owner_email)
        from public.listing_claims c
       where c.venue_id = p_venue and c.approved_at is not null
      union all
      select x.created_at, jsonb_build_object(
               'at', x.created_at, 'kind', 'draft_' || x.status,
               'title', case x.status
                          when 'submitted' then 'Owner submitted changes'
                          when 'declined' then 'Sent back with a note'
                          else 'Changes put on the page' end,
               'detail', x.owner_email,
               'text', x.note,
               'draft', x.draft)
        from public.owner_draft_events x where x.venue_id = p_venue
      union all
      select e.created_at, jsonb_build_object(
               'at', e.created_at, 'kind', 'email',
               'title', 'Email: ' || e.subject,
               'detail', 'To ' || e.to_email || case e.status when 'sent' then '' else ' (' || e.status || ')' end,
               'text', e.body, 'link', e.cta_url)
        from public.owner_emails e where e.venue_id = p_venue
      union all
      select u.created_at, jsonb_build_object(
               'at', u.created_at, 'kind', 'suggested',
               'title', 'Visitor suggested an update',
               'detail', array_to_string(u.kinds, ', '),
               'text', u.details)
        from public.listing_updates u where u.venue_id = p_venue
    ) t
   where t.at is not null;
  return out;
end $$;
revoke all on function public.admin_space_trail(uuid) from public;
grant execute on function public.admin_space_trail(uuid) to authenticated;
