-- ============================================================
-- Migration 66: booking requests (enquiries) for Verified listings.
-- (Applied automatically by the build; nothing to paste.)
--
-- A nomad taps "Request a booking" on a nomadwise.io listing, fills
-- the short form on Nomad Maps, and the request lands here. A trigger
-- emails it to the listing's enquiry address (the owner) with a copy
-- to hello@nomadwise.io, through Resend, using the API key kept in
-- Vault under the name `resend_api_key`. Until that key exists the
-- request is stored with status 'failed' and the reason, so nothing
-- is lost; the control centre shows it and it can be re-sent.
-- ============================================================

create table if not exists public.enquiries (
  id            uuid primary key default gen_random_uuid(),
  venue_id      uuid not null references public.venues(id) on delete cascade,
  name          text not null check (char_length(name) between 1 and 120),
  email         text not null check (position('@' in email) > 1 and char_length(email) <= 200),
  phone         text check (char_length(phone) <= 60),
  want          text not null default 'other'
                check (want in ('day_pass','desk_month','event','other')),
  dates         text check (char_length(dates) <= 200),
  people        integer check (people between 1 and 500),
  message       text check (char_length(message) <= 3000),
  source        text not null default 'nomadwise',
  status        text not null default 'new'
                check (status in ('new','sent','failed')),
  to_email      text,
  sent_at       timestamptz,
  send_error    text,
  resend_id     text,
  created_at    timestamptz not null default now()
);

create index if not exists idx_enquiries_venue on public.enquiries(venue_id, created_at desc);
create index if not exists idx_enquiries_status on public.enquiries(status) where status <> 'sent';

alter table public.enquiries enable row level security;

-- Anyone can file a request (the form is public); only admins read.
drop policy if exists "enquiries insert public" on public.enquiries;
create policy "enquiries insert public" on public.enquiries
  for insert to anon, authenticated
  with check (status = 'new' and sent_at is null and to_email is null);

drop policy if exists "enquiries admin" on public.enquiries;
create policy "enquiries admin" on public.enquiries
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Gentle limits: at most 5 requests an hour from one address, and
-- 20 an hour to one listing, so a script cannot flood an owner.
create or replace function public.enquiry_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.enquiries
       where email = new.email and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Too many requests from this address; try again later.';
  end if;
  if (select count(*) from public.enquiries
       where venue_id = new.venue_id and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'This listing has had a lot of requests in the last hour; try again later.';
  end if;
  return new;
end $$;

drop trigger if exists enquiry_guard on public.enquiries;
create trigger enquiry_guard before insert on public.enquiries
  for each row execute function public.enquiry_guard();

-- The email. Plain text, the request's details, reply-to the nomad
-- so the owner answers with one tap. Copy to hello@nomadwise.io.
create or replace function public.send_enquiry(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  e   public.enquiries%rowtype;
  v   public.venues%rowtype;
  key text;
  dest text;
  what text;
  body text;
  subj text;
  payload jsonb;
  req  bigint;
begin
  select * into e from public.enquiries where id = p_id;
  if not found then return; end if;
  select * into v from public.venues where id = e.venue_id;

  dest := coalesce(nullif(trim(v.listing_enquiry_email), ''), 'hello@nomadwise.io');

  select decrypted_secret into key
    from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if key is null or key = '' then
    update public.enquiries set status = 'failed', to_email = dest,
      send_error = 'No Resend key in Vault yet (resend_api_key).'
      where id = p_id;
    return;
  end if;

  what := case e.want
            when 'day_pass'   then 'A day pass'
            when 'desk_month' then 'A desk for a month or longer'
            when 'event'      then 'A meeting or event'
            else 'Something else' end;

  subj := 'Booking request for ' || v.name || ' via nomadwise.io';
  body := 'New booking request from nomadwise.io' || E'\n\n'
       || 'Listing:  ' || v.name || E'\n'
       || 'From:     ' || e.name || ' <' || e.email || '>' || E'\n'
       || coalesce('Phone:    ' || nullif(e.phone, '') || E'\n', '')
       || 'Wants:    ' || what || E'\n'
       || coalesce('Dates:    ' || nullif(e.dates, '') || E'\n', '')
       || coalesce('People:   ' || e.people::text || E'\n', '')
       || E'\n' || coalesce(e.message, '') || E'\n\n'
       || 'Reply to this email to answer ' || e.name || ' directly.' || E'\n\n'
       || 'Nomadwise, ' || 'https://www.nomadwise.io/coworking/' || coalesce(v.webflow_slug, '') || E'\n';

  payload := jsonb_build_object(
      'from', 'Nomadwise <hello@nomadwise.io>',
      'to', jsonb_build_array(dest),
      'reply_to', e.email,
      'subject', subj,
      'text', body,
      'tags', jsonb_build_array(jsonb_build_object('name', 'kind', 'value', 'enquiry')));
  if dest <> 'hello@nomadwise.io' then
    payload := payload || jsonb_build_object('cc', jsonb_build_array('hello@nomadwise.io'));
  end if;

  select net.http_post(
    url := 'https://api.resend.com/emails',
    body := payload,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || key,
      'Content-Type', 'application/json'))
  into req;

  update public.enquiries
     set status = 'sent', to_email = dest, sent_at = now(),
         resend_id = req::text, send_error = null
   where id = p_id;
exception when others then
  update public.enquiries set status = 'failed', to_email = dest,
    send_error = left(sqlerrm, 300) where id = p_id;
end $$;

create or replace function public.enquiry_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.send_enquiry(new.id);
  perform public.notify_phone('Booking request', new.name || ' asked about a listing', 'envelope');
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists enquiry_after_insert on public.enquiries;
create trigger enquiry_after_insert after insert on public.enquiries
  for each row execute function public.enquiry_after_insert();

-- Admin re-send (from the control centre) for a failed one.
create or replace function public.resend_enquiry(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  perform public.send_enquiry(p_id);
end $$;
grant execute on function public.resend_enquiry(uuid) to authenticated;

-- The form looks a listing up by its nomadwise.io slug; the public
-- venues policy already allows reading verified venues.
create index if not exists idx_venues_webflow_slug_lookup on public.venues(webflow_slug);

-- The form now exists, so the Request a booking switch can go on for
-- every Verified page: ask the sync to rewrite their fields.
update public.venues
   set listing_sync_requested_at = now(), listing_synced_at = null
 where listing_tier = 'verified' and webflow_cms_id is not null;
