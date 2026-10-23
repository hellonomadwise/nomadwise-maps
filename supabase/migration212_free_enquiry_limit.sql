-- ============================================================
-- Migration 212: 2 free enquiries for claimed free pages, then held
-- for Plus. OFF until a founder switches it on.
-- (Applied automatically by the build; nothing to paste.)
--
-- CR-31, agreed 23 Oct: every page has the Send an enquiry button.
--   * Plus page: every enquiry goes straight to the space (as today).
--   * Claimed free page: the first 2 enquiries in total go straight
--     to the space, and the nomad is told it went (the same email as
--     when we pass one on). From the 3rd, the enquiry is held: the
--     owner is emailed that one is waiting and that Plus brings it to
--     them, and the founders' phones are told (Jonathan, 23 Oct:
--     "hold it for Plus"). When the space goes on Plus, everything
--     held is sent to it at once and each nomad is told.
--   * Page nobody has claimed: as today, it waits in "Enquiries to
--     pass on" for a founder.
-- Held enquiries are listed for the founders under the pass-on list,
-- with "Move to pass on", so a nomad is never left without a way.
-- Counting starts when this is switched on: spaces claimed before
-- start at 0.
--
-- Switched OFF here. While off, nothing changes for anyone: free
-- pages' enquiries wait to be passed on by hand, as today. The new
-- emails (to the space for a free enquiry, and to the owner for a
-- held one) go to Leonie first; to switch on, in the SQL editor:
--   update public.sync_settings
--      set value = jsonb_build_object('on', true, 'limit', 2)
--    where key = 'free_enquiries';
-- Pure ASCII. Safe to apply twice.
-- ============================================================

insert into public.sync_settings (key, value)
values ('free_enquiries', jsonb_build_object('on', false, 'limit', 2))
on conflict (key) do nothing;

-- 1. The enquiries table: which ones used a free place, and held.
alter table public.enquiries
  add column if not exists free_slot   boolean not null default false,
  add column if not exists held_at     timestamptz,
  add column if not exists released_at timestamptz;

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
  check (status in ('new', 'sent', 'failed', 'waiting', 'passed', 'closed', 'held'));

create index if not exists idx_enquiries_free_slot
  on public.enquiries(venue_id) where free_slot;
create index if not exists idx_enquiries_held
  on public.enquiries(venue_id) where status = 'held';

-- 2. The switch and the limit.
create or replace function public.free_enquiry_rule()
returns jsonb language sql stable security definer set search_path = public as $$
  -- A typo in the switch never breaks anything: anything but true is
  -- off, and anything but a whole number is 2.
  select jsonb_build_object(
    'on', coalesce(lower(s.value ->> 'on') = 'true', false),
    'limit', case when (s.value ->> 'limit') ~ '^[0-9]{1,4}$'
                  then (s.value ->> 'limit')::int else 2 end)
    from (select (select value from public.sync_settings
                   where key = 'free_enquiries') as value) s;
$$;
revoke all on function public.free_enquiry_rule() from public, anon, authenticated;

-- Where a space's enquiries go: its enquiry address, else the
-- owner's email. Null when neither looks like an address.
create or replace function public.enquiry_address(p_venue uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
           when lower(btrim(coalesce(v.listing_enquiry_email, ''))) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
             then lower(btrim(v.listing_enquiry_email))
           when lower(btrim(coalesce(v.listing_owner_email, ''))) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
             then lower(btrim(v.listing_owner_email))
         end
    from public.venues v where v.id = p_venue;
$$;
revoke all on function public.enquiry_address(uuid) from public, anon, authenticated;

-- How many free enquiries a space has used, and how many are held.
create or replace function public.free_enquiries_used(p_venue uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.enquiries
   where venue_id = p_venue and free_slot;
$$;
revoke all on function public.free_enquiries_used(uuid) from public, anon, authenticated;

-- 3. Where a new enquiry goes: 'direct' (Plus), 'free' (one of the
-- free ones), 'held' (free ones used up) or 'waiting' (for us).
create or replace function public.enquiry_route(p_venue uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v    public.venues%rowtype;
  rule jsonb := public.free_enquiry_rule();
begin
  if p_venue is null then return 'waiting'; end if;
  select * into v from public.venues where id = p_venue;
  if not found then return 'waiting'; end if;

  if public.enquiry_goes_direct(p_venue) then
    return 'direct';                      -- Plus with an enquiry address
  end if;
  if not (rule ->> 'on')::boolean then
    return 'waiting';                     -- switched off: as before
  end if;
  if coalesce(v.listing_tier, 'free') = 'verified' then
    -- Plus without an enquiry address: the owner's email will do.
    return case when public.enquiry_address(p_venue) is not null
                then 'direct' else 'waiting' end;
  end if;
  if not coalesce(public.listing_has_owner(p_venue), false)
     or public.enquiry_address(p_venue) is null then
    return 'waiting';                     -- nobody to send it to
  end if;
  if public.free_enquiries_used(p_venue) < (rule ->> 'limit')::int then
    return 'free';
  end if;
  return 'held';
end $$;
revoke all on function public.enquiry_route(uuid) from public, anon, authenticated;

-- 4. The email to the space: a free enquiry says which one of the 2
-- it was, and what Plus does. Everything else as in migration 196.
create or replace function public.enquiry_space_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  page  text;
  pitch text;
  first text;
  used  int;
  lim   int;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;

  page := case when v.webflow_slug is not null
               then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  first := nullif(nullif(split_part(trim(e.name), ' ', 1), ''), 'Someone');

  if e.held_at is not null then
    -- Kept while the free enquiries were used up, sent now on Plus.
    pitch := 'About this enquiry' || E'\n'
          || 'We kept this enquiry for you while your free enquiries were used up. '
          || 'Your page is on Plus now, so every enquiry comes straight to you.';
  elsif e.free_slot then
    lim := (public.free_enquiry_rule() ->> 'limit')::int;
    select count(*) into used from public.enquiries x
     where x.venue_id = e.venue_id and x.free_slot
       and (x.created_at, x.id) <= (e.created_at, e.id);
    pitch := 'About your listing' || E'\n'
          || 'This was free enquiry ' || used || ' of ' || lim
          || ' that come with your free plan. '
          || case when used >= lim
                  then 'From the next one, enquiries are kept for you until you move to Plus. '
                  else '' end
          || 'With Plus, every enquiry comes straight to your inbox, and your '
          || 'page gets the Verified by Nomadwise badge and top positioning on '
          || 'your region''s page:' || E'\n'
          || 'https://nomadmaps.io/?owner&billing';
  elsif v.listing_tier = 'verified' then
    pitch := 'Your Verified page does not have an enquiry address yet. Add one in '
          || 'your Owner account and future enquiries will reach you directly:' || E'\n'
          || 'https://nomadmaps.io/?owner';
  elsif coalesce(trim(v.listing_owner_email), '') = '' then
    pitch := 'About your listing' || E'\n'
          || v.name || ' is listed on Nomadwise free of charge, based on publicly '
          || 'available information. You can claim the page at no cost to keep your '
          || 'details up to date and add your own photos, prices and opening hours:' || E'\n'
          || 'https://nomadmaps.io/?claim='
          || coalesce(v.webflow_slug, replace(v.name, ' ', '%20'));
  else
    pitch := 'About your listing' || E'\n'
          || 'Enquiries for your page currently come to us first, and we pass them on '
          || 'to you. With a Verified listing they reach your inbox directly, and your '
          || 'page is shown with the Verified badge above other listings in '
          || coalesce(nullif(v.city, ''), 'your city') || ':' || E'\n'
          || 'https://nomadmaps.io/?owner&billing';
  end if;

  return jsonb_build_object(
    'subject', 'New enquiry for ' || v.name || ' from Nomadwise',
    'body',
      'Hi ' || v.name || ' team,' || E'\n\n'
      || 'You have a new enquiry from a remote worker who found '
      || case when page is not null then 'your page' else 'you' end
      || ' on Nomadwise' || coalesce(': ' || page, '.') || E'\n\n'
      || 'Name: ' || e.name || E'\n'
      || 'Email: ' || e.email || E'\n'
      || coalesce('Phone: ' || nullif(e.phone, '') || E'\n', '')
      || case e.want when 'day_pass' then 'Interested in: a day pass' || E'\n'
                     when 'desk_month' then 'Interested in: a desk for a month or longer' || E'\n'
                     when 'event' then 'Interested in: a meeting or event' || E'\n'
                     else '' end
      || coalesce('Dates: ' || nullif(e.dates, '') || E'\n', '')
      || coalesce('People: ' || e.people::text || E'\n', '')
      || 'Sent: ' || to_char(e.created_at at time zone 'utc', 'FMDD Mon YYYY') || E'\n\n'
      || 'Their message:' || E'\n'
      || coalesce(nullif(btrim(e.message), ''), '(No message)') || E'\n\n'
      || 'To reply, simply answer this email. Your reply goes directly to '
      || coalesce(first, 'them') || '.' || E'\n\n'
      || pitch || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;
revoke all on function public.enquiry_space_email(uuid) from public, anon, authenticated;

-- 5. Sending one enquiry to its space now, and telling the nomad.
-- Used for a free enquiry and for a held one released by Plus.
-- Raises if the email could not be handed over (the caller decides).
create or replace function public.enquiry_send_to_space(p_id uuid, p_kind text)
returns text language plpgsql security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  dest  text;
  draft jsonb;
  nd    jsonb;
begin
  select * into e from public.enquiries where id = p_id for update;
  if not found or e.venue_id is null then
    raise exception 'Enquiry not found.';
  end if;
  if e.status not in ('new', 'held') then
    raise exception 'This enquiry has already been dealt with.';
  end if;
  dest := public.enquiry_address(e.venue_id);
  if dest is null then
    raise exception 'No address for this space.';
  end if;
  draft := public.enquiry_space_email(p_id);
  perform public.send_enquiry_mail(
    dest, e.email, draft ->> 'subject', draft ->> 'body',
    p_kind, e.id::text, e.venue_id);
  update public.enquiries
     set status = 'sent', to_email = dest, sent_at = now(), send_error = null,
         released_at = case when status = 'held' then now() else released_at end
   where id = p_id;

  -- The nomad hears it went, as when we pass one on. Never in the way
  -- of the email that has just gone.
  begin
    nd := public.enquiry_nomad_email(array[p_id]);
    perform public.send_enquiry_mail(
      e.email, 'hello@nomadwise.io', nd ->> 'subject', nd ->> 'body',
      'enquiry_passed_nomad', e.id::text, e.venue_id, null);
    update public.enquiries set nomad_emailed_at = now() where id = p_id;
  exception when others then
    null;
  end;
  return dest;
end $$;
revoke all on function public.enquiry_send_to_space(uuid, text) from public, anon, authenticated;

-- 6. The owner's email about a held enquiry.
create or replace function public.enquiry_held_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  first text;
  lim   int := (public.free_enquiry_rule() ->> 'limit')::int;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;
  first := nullif(split_part(btrim(coalesce(v.listing_owner_name, '')), ' ', 1), '');
  return jsonb_build_object(
    'to', public.enquiry_address(v.id),
    'subject', 'A new enquiry for ' || v.name || ' is waiting for you',
    'body',
      'Hi ' || coalesce(first, v.name || ' team') || ',' || E'\n\n'
      || 'A remote worker has just sent ' || v.name || ' an enquiry through your '
      || 'page on Nomadwise.' || E'\n\n'
      || 'You have used the ' || lim || ' free enquiries that come with the free '
      || 'plan, so we are keeping this one for you. With Plus, it comes straight to '
      || 'your inbox, along with every enquiry after it, and your page gets the '
      || 'Verified by Nomadwise badge and top positioning on your region''s page.'
      || E'\n\n'
      || 'If you have any questions, simply reply to this email.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;
revoke all on function public.enquiry_held_email(uuid) from public, anon, authenticated;

-- 7. A new enquiry finds its way (replaces migration 113's version).
create or replace function public.enquiry_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  vname text;
  route text;
  dest  text;
  n     int;
  lim   int;
  mail  jsonb;
begin
  if new.status <> 'new' then
    return new;           -- history, or filed by hand
  end if;
  select name into vname from public.venues where id = new.venue_id;
  begin
    route := public.enquiry_route(new.venue_id);
  exception when others then
    route := 'waiting';   -- never lost: a founder passes it on
  end;

  if route = 'free' then
    begin
      update public.enquiries set free_slot = true where id = new.id;
      dest := public.enquiry_send_to_space(new.id, 'enquiry_free');
      n := public.free_enquiries_used(new.venue_id);
      lim := (public.free_enquiry_rule() ->> 'limit')::int;
      perform public.notify_phone(
        'Free enquiry ' || n || ' of ' || lim || ' sent to ' || coalesce(vname, 'a space'),
        new.name || ' wrote: ' || left(coalesce(new.message, ''), 120),
        'envelope');
      return new;
    exception when others then
      -- Could not be sent: it waits for a founder instead (the free
      -- place is given back, as the block is undone).
      route := 'waiting';
    end;
  end if;

  if route = 'held' then
    update public.enquiries set status = 'held', held_at = now() where id = new.id;
    begin
      mail := public.enquiry_held_email(new.id);
      perform public.send_owner_email(
        mail ->> 'to', mail ->> 'subject', mail ->> 'body',
        'enquiry_held', new.id::text,
        'Get Plus', 'https://nomadmaps.io/?owner&billing');
    exception when others then
      null;               -- still held; the founders are told below
    end;
    perform public.notify_phone(
      'Enquiry held for Plus: ' || coalesce(vname, 'a space'),
      new.name || ' wrote: ' || left(coalesce(new.message, ''), 120)
        || E'\nTheir free enquiries are used. Move it to pass on if you want it to go.',
      'envelope');
    return new;
  end if;

  if route = 'direct' and coalesce(public.enquiry_goes_direct(new.venue_id), false) then
    perform public.send_enquiry(new.id);
    perform public.notify_phone(
      'Enquiry sent to ' || coalesce(vname, 'a Verified space'),
      new.name || ' wrote: ' || left(coalesce(new.message, ''), 120),
      'envelope');
  elsif route = 'direct' then
    -- Plus with only the owner's email (switch on).
    begin
      dest := public.enquiry_send_to_space(new.id, 'enquiry');
      perform public.notify_phone(
        'Enquiry sent to ' || coalesce(vname, 'a Plus space'),
        new.name || ' wrote: ' || left(coalesce(new.message, ''), 120),
        'envelope');
      return new;
    exception when others then
      route := 'waiting';
    end;
  end if;

  if route = 'waiting' then
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

-- 8. On Plus: everything held for the space is sent to it at once.
create or replace function public.release_held_enquiries(p_venue uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  r  record;
  n  int := 0;
begin
  for r in select id from public.enquiries
            where venue_id = p_venue and status = 'held'
            order by created_at
  loop
    begin
      perform public.enquiry_send_to_space(r.id, 'enquiry_released');
      n := n + 1;
    exception when others then
      -- left held; it shows to the founders under the pass-on list
      null;
    end;
  end loop;
  if n > 0 then
    perform public.notify_phone(
      n || ' held enquir' || case when n = 1 then 'y' else 'ies' end || ' sent',
      coalesce((select name from public.venues where id = p_venue), 'A space')
        || ' is on Plus now, so what was held went to them.',
      'envelope');
  end if;
  return n;
end $$;
revoke all on function public.release_held_enquiries(uuid) from public, anon, authenticated;

create or replace function public.venue_plus_releases()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.listing_tier = 'verified'
     and coalesce(old.listing_tier, '') <> 'verified' then
    begin
      perform public.release_held_enquiries(new.id);
    exception when others then
      null;               -- never in the way of the plan change
    end;
  end if;
  return new;
end $$;

drop trigger if exists venue_plus_releases on public.venues;
create trigger venue_plus_releases
  after update of listing_tier on public.venues
  for each row execute function public.venue_plus_releases();

-- 9. The founders: held enquiries next to the pass-on list, and a
-- way to pass one on anyway.
create or replace function public.admin_enquiries_held()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return jsonb_build_object(
    'on', (public.free_enquiry_rule() ->> 'on')::boolean,
    'limit', (public.free_enquiry_rule() ->> 'limit')::int,
    'held', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'name', e.name, 'email', e.email,
               'message', e.message, 'created_at', e.created_at,
               'venue_id', v.id, 'venue_name', v.name, 'city', v.city)
             order by e.created_at)
        from public.enquiries e
        join public.venues v on v.id = e.venue_id
       where e.status = 'held'), '[]'::jsonb));
end $$;
revoke all on function public.admin_enquiries_held() from public, anon;
grant execute on function public.admin_enquiries_held() to authenticated;

create or replace function public.admin_enquiry_unhold(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  update public.enquiries set status = 'waiting'
   where id = p_id and status = 'held';
  if not found then
    raise exception 'This enquiry is no longer held.';
  end if;
end $$;
revoke all on function public.admin_enquiry_unhold(uuid) from public, anon;
grant execute on function public.admin_enquiry_unhold(uuid) to authenticated;

-- 10. The Owner account: how many free enquiries are left.
create or replace function public.owner_enquiry_allowance(p_venue uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v    public.venues%rowtype;
  rule jsonb := public.free_enquiry_rule();
  used int;
begin
  v := public.billing_venue(p_venue, false);   -- the owner, or a founder
  used := public.free_enquiries_used(p_venue);
  return jsonb_build_object(
    'on', (rule ->> 'on')::boolean,
    'plus', coalesce(v.listing_tier, 'free') = 'verified',
    'limit', (rule ->> 'limit')::int,
    'used', used,
    'left', greatest((rule ->> 'limit')::int - used, 0),
    'held', (select count(*) from public.enquiries
              where venue_id = p_venue and status = 'held'));
end $$;
revoke all on function public.owner_enquiry_allowance(uuid) from public, anon;
grant execute on function public.owner_enquiry_allowance(uuid) to authenticated;

notify pgrst, 'reload schema';
