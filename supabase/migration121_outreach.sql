-- ============================================================
-- Migration 121: Outreach, the control centre's list of spaces we
-- talk to.
-- (Applied automatically by the build; nothing to paste.)
--
-- For a year, cafes and coworking spaces have written to
-- hello@nomadwise.io asking to be listed, or asking for changes to a
-- page, and the answer was "when the members area is ready". It is
-- ready. This gives the founders one place for all of them:
--
--   space_contacts      one row per space (or per person who wrote):
--                       who, where, how they reached us, which stage
--                       they are at, notes, and a link to the venue on
--                       the map when we can match it.
--   outreach_messages   what they wrote and what we sent, per contact.
--   outreach_templates  the emails we send, with placeholders, so the
--                       words can change without a build.
--
-- Stages: new (they wrote, we have not answered), contacted (we wrote),
-- replied (they answered our email), claimed (they claimed a page),
-- verified (they pay), not_now, declined, unsubscribed, bounced.
-- claimed and verified move by themselves from listing_claims and
-- venues; the rest are set by a founder.
--
-- Sending goes through Postmark like the owner emails, from
-- hello@nomadwise.io, and is logged. Guard rails: never to a contact
-- who unsubscribed; no second email to the same contact within 30
-- days unless the founder says so; at most 40 outreach emails a day.
-- Every email carries an unsubscribe link (public.outreach_unsubscribe
-- handles the click, via nomadmaps.io/?unsubscribe=<token>).
--
-- Webflow's business forms (Add Coworking Space, Add Cafe,
-- Recommendations from Users) are read by the website sync and filed
-- here through import_webflow_outreach(); the pop-up enquiry form is
-- not (that is migration 113).
--
-- The year of emails already in the inbox comes in through
-- admin_outreach_import(), from a file a founder copies and imports in
-- the app. It is deliberately not a migration: the site is built from
-- this repository, and people's names, addresses and messages do not
-- belong in it.
-- ============================================================

-- ------------------------------------------------------------ tables
create table if not exists public.space_contacts (
  id               uuid primary key default gen_random_uuid(),
  venue_id         uuid references public.venues(id) on delete set null,
  space_name       text,
  kind             text,              -- cafe, coworking, coliving, hotel, restaurant, other
  city             text,
  country          text,
  person_name      text,
  email            text,
  phone            text,
  website          text,
  instagram        text,
  source           text not null default 'email'
                   check (source in ('email', 'webflow_form', 'listing', 'prospect', 'enquiry', 'manual')),
  source_ref       text,              -- Gmail thread id, Webflow submission id
  form_name        text,
  stage            text not null default 'new'
                   check (stage in ('new', 'contacted', 'replied', 'claimed', 'verified',
                                    'not_now', 'declined', 'unsubscribed', 'bounced')),
  stage_at         timestamptz not null default now(),
  first_in_at      timestamptz,       -- when they first wrote to us
  last_in_at       timestamptz,
  last_out_at      timestamptz,
  follow_up_on     date,
  notes            text,
  -- gen_random_uuid() is built in; pgcrypto's gen_random_bytes() lives
  -- in Supabase's "extensions" schema and is not found from here.
  unsub_token      text not null unique default replace(gen_random_uuid()::text, '-', ''),
  unsubscribed_at  timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index if not exists space_contacts_email_key
  on public.space_contacts (lower(email)) where email is not null;
create index if not exists space_contacts_stage_idx on public.space_contacts (stage, stage_at desc);
create index if not exists space_contacts_venue_idx on public.space_contacts (venue_id);

create table if not exists public.outreach_messages (
  id            uuid primary key default gen_random_uuid(),
  contact_id    uuid not null references public.space_contacts(id) on delete cascade,
  direction     text not null check (direction in ('in', 'out')),
  template_key  text,
  subject       text,
  body          text,
  at            timestamptz not null default now(),
  source_ref    text,                 -- Gmail thread or Webflow submission for 'in'
  postmark_id   text,
  send_error    text,
  sent_by       text
);
create index if not exists outreach_messages_contact_idx on public.outreach_messages (contact_id, at desc);
create unique index if not exists outreach_messages_source_ref_key
  on public.outreach_messages (source_ref) where source_ref is not null;

create table if not exists public.outreach_templates (
  key        text primary key,
  name       text not null,
  subject    text not null,
  body       text not null,
  stream     text not null default 'outbound',   -- Postmark message stream
  sort       integer not null default 100,
  updated_at timestamptz not null default now()
);

alter table public.space_contacts    enable row level security;
alter table public.outreach_messages enable row level security;
alter table public.outreach_templates enable row level security;
-- Founders only, through the functions below (security definer).
revoke all on public.space_contacts, public.outreach_messages, public.outreach_templates
  from public, anon, authenticated;

-- ---------------------------------------------------------- templates
-- Placeholders: {first_name} {name} {space} {city} {page_link}
-- {claim_link} {price_words} {unsubscribe_link} {signoff}.
-- Rules for the words: no em dashes, no promises of a time, prices with
-- their symbol, "Owner account" never "members area".
insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('reply_listing', 'Reply: they asked how to list',
 'Listing {space} on Nomadwise',
 'Hi {first_name},

Thank you for writing to us about {space}, and sorry it took us a while to come back to you properly. We have been rebuilding how spaces join Nomadwise, and that is now live.

There are two ways to be on nomadwise.io. A free page, which you set up yourself in three steps and keep up to date from your own Owner account. And Verified, which adds the Verified badge, a place above every free listing in your city, and a Send an enquiry button that emails you directly, for {price_words}, monthly or yearly, cancel any time. There is no commission on anything.

To get {space} on: {claim_link}

Find your space, or add it from Google Maps if it is not on our map yet, tell us where enquiries should go, and choose Free or Verified. We check every claim is from the team, then the page is yours.

If anything is unclear, reply to this email and a person answers.

{signoff}', 'outbound', 10),

('reply_already_listed', 'Reply: already listed, wants changes',
 'Your page on Nomadwise is ready to claim',
 'Hi {first_name},

{space} is already on nomadwise.io: {page_link}

You can now take the page over yourself. Claim it here: {claim_link}

It is free. You get an Owner account where you can correct the facts and add your own photos, description and prices, and every change is read by a person before it goes live. If you would like the Verified badge, a place above every free listing in your city and enquiries straight to your inbox, that is {price_words}, monthly or yearly, cancel any time.

About the changes you asked for: once you have claimed the page you can make them yourself, or reply with them here and we put them on for you.

{signoff}', 'outbound', 20),

('reply_fee', 'Reply: they asked about the old fee',
 'About {space} and the fee you asked about',
 'Hi {first_name},

Thank you for your note about {space}. The fee you saw belonged to our old form, which has gone.

Listing on nomadwise.io is free. You set up your page yourself in three steps and keep it up to date from your own Owner account. If you want more, Verified adds the Verified badge, a place above every free listing in your city, and a Send an enquiry button that emails you directly, for {price_words}, monthly or yearly, cancel any time. No commission on anything, ever.

To get {space} on: {claim_link}

Reply to this email if you have any questions and a person answers.

{signoff}', 'outbound', 30),

('follow_up', 'Follow-up: a short nudge',
 'Still interested in listing {space}?',
 'Hi {first_name},

A short follow-up on {space}. The claim form is here: {claim_link}

Free to list, and Verified for {price_words} if you want the badge, the placement above free listings and enquiries straight to your inbox.

If now is not the time, no problem at all. Reply with a word and we leave it there.

{signoff}', 'outbound', 40),

('invite_listed', 'Invitation: you are on Nomadwise, claim your page',
 '{space} is on nomadwise.io',
 'Hi there,

{space} has a page on nomadwise.io, the directory nomads use to find a place to work from: {page_link}

We would like you to have it. Claiming is free and takes three steps: find your space, tell us where enquiries should go, and the page is yours to keep up to date from your own Owner account. If you want more, Verified adds the Verified badge, a place above every free listing in your city and enquiries straight to your inbox, for {price_words}, monthly or yearly, cancel any time.

Claim your page: {claim_link}

We will not write again unless you reply. If you would rather not hear from us at all: {unsubscribe_link}

{signoff}', 'outbound', 50)
on conflict (key) do nothing;

-- ---------------------------------------------------------- helpers
create or replace function public.outreach_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.stage is distinct from old.stage then new.stage_at := now(); end if;
  return new;
end $$;
drop trigger if exists space_contacts_touch on public.space_contacts;
create trigger space_contacts_touch before update on public.space_contacts
  for each row execute function public.outreach_touch();

-- The venue on the map for a contact, from the venue it already has,
-- or by name and city.
create or replace function public.outreach_match_venue(p_name text, p_city text)
returns uuid language sql stable security definer set search_path = public as $$
  select public.match_listing(
    case when coalesce(trim(p_city), '') = '' then trim(coalesce(p_name, ''))
         else trim(coalesce(p_name, '')) || ', ' || trim(p_city) end);
$$;

-- One contact per email: add, or update the blanks on the existing row.
-- Returns the contact id. Service role (imports) and founders.
create or replace function public.outreach_upsert(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  em  text := nullif(lower(trim(coalesce(p->>'email', ''))), '');
  nm  text := nullif(trim(coalesce(p->>'space_name', '')), '');
  cid uuid;
  vid uuid;
begin
  if em is not null and position('@' in em) < 2 then em := null; end if;
  if em is null and nm is null then
    raise exception 'A contact needs an email or a space name.';
  end if;

  if em is not null then
    select id into cid from public.space_contacts where lower(email) = em;
  end if;
  if cid is null and nm is not null then
    select id into cid from public.space_contacts
     where email is null and lower(trim(space_name)) = lower(nm)
       and lower(coalesce(city, '')) = lower(coalesce(p->>'city', ''))
     limit 1;
  end if;

  vid := case when (p->>'venue_id') ~ '^[0-9a-f-]{36}$' then (p->>'venue_id')::uuid end;
  if vid is null and nm is not null then
    vid := public.outreach_match_venue(nm, p->>'city');
  end if;

  if cid is null then
    insert into public.space_contacts
      (venue_id, space_name, kind, city, country, person_name, email, phone,
       website, instagram, source, source_ref, form_name, stage, first_in_at,
       last_in_at, notes)
    values
      (vid, nm, nullif(trim(p->>'kind'), ''), nullif(trim(p->>'city'), ''),
       nullif(trim(p->>'country'), ''), nullif(trim(p->>'person_name'), ''), em,
       nullif(trim(p->>'phone'), ''), nullif(trim(p->>'website'), ''),
       nullif(trim(p->>'instagram'), ''),
       coalesce(nullif(p->>'source', ''), 'email'), nullif(p->>'source_ref', ''),
       nullif(p->>'form_name', ''),
       coalesce(nullif(p->>'stage', ''), 'new'),
       nullif(p->>'first_in_at', '')::timestamptz,
       nullif(p->>'first_in_at', '')::timestamptz,
       nullif(trim(p->>'notes'), ''))
    returning id into cid;
  else
    update public.space_contacts c set
      venue_id    = coalesce(c.venue_id, vid),
      space_name  = coalesce(c.space_name, nm),
      kind        = coalesce(c.kind, nullif(trim(p->>'kind'), '')),
      city        = coalesce(c.city, nullif(trim(p->>'city'), '')),
      country     = coalesce(c.country, nullif(trim(p->>'country'), '')),
      person_name = coalesce(c.person_name, nullif(trim(p->>'person_name'), '')),
      email       = coalesce(c.email, em),
      phone       = coalesce(c.phone, nullif(trim(p->>'phone'), '')),
      website     = coalesce(c.website, nullif(trim(p->>'website'), '')),
      instagram   = coalesce(c.instagram, nullif(trim(p->>'instagram'), '')),
      first_in_at = least(c.first_in_at, nullif(p->>'first_in_at', '')::timestamptz),
      last_in_at  = greatest(c.last_in_at, nullif(p->>'first_in_at', '')::timestamptz),
      notes       = case when nullif(trim(p->>'notes'), '') is null then c.notes
                         when c.notes is null then trim(p->>'notes')
                         when position(trim(p->>'notes') in c.notes) > 0 then c.notes
                         else c.notes || E'\n' || trim(p->>'notes') end
    where c.id = cid;
  end if;

  -- What they wrote, once per source.
  if nullif(p->>'message', '') is not null then
    insert into public.outreach_messages (contact_id, direction, subject, body, at, source_ref)
    values (cid, 'in', nullif(p->>'subject', ''), left(p->>'message', 4000),
            coalesce(nullif(p->>'first_in_at', '')::timestamptz, now()),
            nullif(p->>'source_ref', ''))
    on conflict (source_ref) where source_ref is not null do nothing;
  end if;
  return cid;
end $$;
revoke all on function public.outreach_upsert(jsonb) from public, anon, authenticated;
grant execute on function public.outreach_upsert(jsonb) to service_role;

-- A Webflow business-form submission, from the website sync. The field
-- names differ by form, so each is found by what it is called.
create or replace function public.import_webflow_outreach(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare
  f     jsonb := coalesce(p->'fields', '{}'::jsonb);
  k     text;
  v     text;
  lk    text;
  em    text; nm text; loc text; who text; ig text; web text; ph text;
  dump  text := '';
  cid   uuid;
begin
  if nullif(p->>'id', '') is null then return 'invalid'; end if;
  if exists (select 1 from public.outreach_messages where source_ref = 'wf:' || (p->>'id')) then
    return 'known';
  end if;
  -- The enquiry pop-up is a nomad writing to a space, not a space
  -- writing to us (migration 113 files those).
  if exists (select 1 from public.enquiries where webflow_submission_id = p->>'id') then
    return 'enquiry';
  end if;
  for k, v in select key, value #>> '{}' from jsonb_each(f) loop
    if v is null or trim(v) = '' then continue; end if;
    lk := lower(k);
    dump := dump || k || ': ' || v || E'\n';
    if em is null and lk like '%email%' and position('@' in v) > 1 then em := trim(v);
    elsif nm is null and (lk like 'name of space%' or lk like 'name of cafe%' or lk like 'name of coworking%'
                          or lk like 'space name%' or lk like 'business name%' or lk like 'cafe name%'
                          or lk = 'name of your space') then nm := trim(v);
    elsif loc is null and (lk like 'location%' or lk like 'city%' or lk like 'address%') then loc := trim(v);
    elsif who is null and (lk like 'your name%' or lk like 'name of customer%' or lk like 'contact name%'
                           or lk = 'name' or lk like 'first name%') then who := trim(v);
    elsif ig is null and lk like '%instagram%' then ig := trim(v);
    elsif web is null and (lk like '%website%' or lk like '%url%') then web := trim(v);
    elsif ph is null and (lk like '%phone%' or lk like '%whatsapp%' or lk like '%contact number%') then ph := trim(v);
    end if;
  end loop;
  if em is null and nm is null then return 'invalid'; end if;

  cid := public.outreach_upsert(jsonb_build_object(
    'email', em, 'space_name', nm, 'city', loc, 'person_name', who,
    'instagram', ig, 'website', web, 'phone', ph,
    'source', 'webflow_form', 'source_ref', 'wf:' || (p->>'id'),
    'form_name', nullif(p->>'form_name', ''),
    'first_in_at', nullif(p->>'submitted_at', ''),
    'subject', coalesce(nullif(p->>'form_name', ''), 'Webflow form'),
    'message', rtrim(dump)));
  return 'filed';
end $$;
revoke all on function public.import_webflow_outreach(jsonb) from public, anon, authenticated;
grant execute on function public.import_webflow_outreach(jsonb) to service_role;

-- --------------------------------------------------- stages that move
-- A claim with the contact's email: claimed. Verified on the venue with
-- the contact's email as owner: verified.
create or replace function public.outreach_on_claim()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.space_contacts c
     set stage = 'claimed',
         venue_id = coalesce(c.venue_id, new.venue_id),
         notes = concat_ws(E'\n', nullif(c.notes, ''),
                           'Claimed ' || coalesce(new.space_name, '') || ' on '
                           || to_char(now(), 'DD Mon YYYY') || '.')
   where lower(c.email) = lower(trim(new.owner_email))
     and c.stage not in ('claimed', 'verified');
  return new;
end $$;
drop trigger if exists outreach_on_claim on public.listing_claims;
create trigger outreach_on_claim after insert on public.listing_claims
  for each row execute function public.outreach_on_claim();

create or replace function public.outreach_on_verified()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.listing_tier = 'verified' and old.listing_tier is distinct from 'verified'
     and coalesce(new.listing_owner_email, '') <> '' then
    update public.space_contacts c
       set stage = 'verified', venue_id = coalesce(c.venue_id, new.id)
     where lower(c.email) = lower(trim(new.listing_owner_email))
       and c.stage <> 'verified';
  end if;
  return new;
end $$;
drop trigger if exists outreach_on_verified on public.venues;
create trigger outreach_on_verified after update of listing_tier on public.venues
  for each row execute function public.outreach_on_verified();

-- -------------------------------------------------------- unsubscribe
-- The link in every outreach email: nomadmaps.io/?unsubscribe=<token>.
create or replace function public.outreach_unsubscribe(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.space_contacts%rowtype;
begin
  select * into c from public.space_contacts where unsub_token = trim(coalesce(p_token, ''));
  if not found then return jsonb_build_object('ok', false); end if;
  update public.space_contacts
     set unsubscribed_at = coalesce(unsubscribed_at, now()),
         stage = case when stage in ('claimed', 'verified') then stage else 'unsubscribed' end
   where id = c.id;
  return jsonb_build_object('ok', true, 'space', c.space_name, 'email', c.email);
end $$;
grant execute on function public.outreach_unsubscribe(text) to anon, authenticated, service_role;

-- ------------------------------------------------------------ founders
create or replace function public.admin_outreach_counts()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then
    coalesce((select jsonb_object_agg(stage, n)
                from (select stage, count(*) n from public.space_contacts group by stage) x),
             '{}'::jsonb) end;
$$;
revoke all on function public.admin_outreach_counts() from public, anon;
grant execute on function public.admin_outreach_counts() to authenticated;

-- The list: one stage (or all), optional search, newest activity first.
create or replace function public.admin_outreach_list(p_stage text default null, p_q text default null, p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := lower(trim(coalesce(p_q, '')));
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.sort_at desc)
      from (
        select c.id, c.venue_id, c.space_name, c.kind, c.city, c.country,
               c.person_name, c.email, c.phone, c.website, c.instagram,
               c.source, c.form_name, c.stage, c.stage_at, c.first_in_at,
               c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.unsubscribed_at,
               greatest(coalesce(c.last_in_at, c.created_at), coalesce(c.last_out_at, c.created_at), c.stage_at) as sort_at,
               v.name as venue_name, v.city as venue_city, v.country as venue_country,
               v.webflow_slug, (v.webflow_cms_id is not null) as on_site,
               v.listing_tier, v.listing_owner_email,
               (select m.body from public.outreach_messages m
                 where m.contact_id = c.id and m.direction = 'in'
                 order by m.at desc limit 1) as last_in,
               (select count(*) from public.outreach_messages m where m.contact_id = c.id) as message_count
          from public.space_contacts c
          left join public.venues v on v.id = c.venue_id
         where (p_stage is null or p_stage = '' or c.stage = p_stage)
           and (q = '' or lower(coalesce(c.space_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.email, '')) like '%' || q || '%'
                       or lower(coalesce(c.person_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.city, '')) like '%' || q || '%'
                       or lower(coalesce(c.country, '')) like '%' || q || '%'
                       or lower(coalesce(v.name, '')) like '%' || q || '%')
         order by sort_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer) to authenticated;

create or replace function public.admin_outreach_messages(p_contact uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then
    coalesce((select jsonb_agg(to_jsonb(m) order by m.at)
                from public.outreach_messages m where m.contact_id = p_contact), '[]'::jsonb) end;
$$;
revoke all on function public.admin_outreach_messages(uuid) from public, anon;
grant execute on function public.admin_outreach_messages(uuid) to authenticated;

create or replace function public.admin_outreach_templates()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then
    coalesce((select jsonb_agg(to_jsonb(t) order by t.sort) from public.outreach_templates t), '[]'::jsonb) end;
$$;
revoke all on function public.admin_outreach_templates() from public, anon;
grant execute on function public.admin_outreach_templates() to authenticated;

create or replace function public.admin_outreach_save_template(p_key text, p_subject text, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.outreach_templates
     set subject = trim(p_subject), body = p_body, updated_at = now()
   where key = p_key;
end $$;
revoke all on function public.admin_outreach_save_template(text, text, text) from public, anon;
grant execute on function public.admin_outreach_save_template(text, text, text) to authenticated;

create or replace function public.admin_outreach_add(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return public.outreach_upsert(p || jsonb_build_object(
           'source', coalesce(nullif(p->>'source', ''), 'manual')));
end $$;
revoke all on function public.admin_outreach_add(jsonb) from public, anon;
grant execute on function public.admin_outreach_add(jsonb) to authenticated;

create or replace function public.admin_outreach_update(p_id uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.space_contacts c set
    stage        = coalesce(nullif(p->>'stage', ''), c.stage),
    notes        = case when p ? 'notes' then nullif(trim(p->>'notes'), '') else c.notes end,
    follow_up_on = case when p ? 'follow_up_on' then nullif(p->>'follow_up_on', '')::date else c.follow_up_on end,
    venue_id     = case when p ? 'venue_id' then nullif(p->>'venue_id', '')::uuid
                        -- A new name or city: look for the space on the map again.
                        when (p ? 'space_name' or p ? 'city') then
                          coalesce(public.outreach_match_venue(
                                     coalesce(nullif(trim(p->>'space_name'), ''), c.space_name),
                                     case when p ? 'city' then nullif(trim(p->>'city'), '') else c.city end),
                                   c.venue_id)
                        else c.venue_id end,
    space_name   = coalesce(nullif(trim(p->>'space_name'), ''), c.space_name),
    person_name  = case when p ? 'person_name' then nullif(trim(p->>'person_name'), '') else c.person_name end,
    email        = case when p ? 'email' then nullif(lower(trim(p->>'email')), '') else c.email end,
    phone        = case when p ? 'phone' then nullif(trim(p->>'phone'), '') else c.phone end,
    city         = case when p ? 'city' then nullif(trim(p->>'city'), '') else c.city end,
    country      = case when p ? 'country' then nullif(trim(p->>'country'), '') else c.country end,
    kind         = case when p ? 'kind' then nullif(trim(p->>'kind'), '') else c.kind end,
    website      = case when p ? 'website' then nullif(trim(p->>'website'), '') else c.website end,
    instagram    = case when p ? 'instagram' then nullif(trim(p->>'instagram'), '') else c.instagram end
  where c.id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
end $$;
revoke all on function public.admin_outreach_update(uuid, jsonb) from public, anon;
grant execute on function public.admin_outreach_update(uuid, jsonb) to authenticated;

-- Something they wrote (pasted from the inbox), kept with the contact.
create or replace function public.admin_outreach_log_in(p_id uuid, p_text text, p_at timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if nullif(trim(p_text), '') is null then return; end if;
  insert into public.outreach_messages (contact_id, direction, body, at)
  values (p_id, 'in', left(trim(p_text), 4000), coalesce(p_at, now()));
  update public.space_contacts
     set last_in_at = greatest(coalesce(last_in_at, p_at), p_at),
         stage = case when stage in ('contacted', 'not_now') then 'replied' else stage end
   where id = p_id;
end $$;
revoke all on function public.admin_outreach_log_in(uuid, text, timestamptz) from public, anon;
grant execute on function public.admin_outreach_log_in(uuid, text, timestamptz) to authenticated;

-- A template with the contact's details filled in: {subject, body}.
create or replace function public.admin_outreach_preview(p_id uuid, p_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c   public.space_contacts%rowtype;
  v   public.venues%rowtype;
  t   public.outreach_templates%rowtype;
  first_name text;
  space text;
  city  text;
  page_link text;
  claim_link text;
  price text;
  subj text;
  body text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
  select * into t from public.outreach_templates where key = p_key;
  if not found then raise exception 'No such template.'; end if;
  if c.venue_id is not null then
    select * into v from public.venues where id = c.venue_id;
  end if;

  first_name := coalesce(nullif(split_part(trim(coalesce(c.person_name, '')), ' ', 1), ''), 'there');
  space := coalesce(nullif(trim(c.space_name), ''), v.name, 'your space');
  city  := coalesce(nullif(trim(c.city), ''), v.city, 'your city');
  page_link := case when v.webflow_cms_id is not null and coalesce(v.webflow_slug, '') <> ''
                    then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  claim_link := 'https://nomadmaps.io/?claim='
             || public.form_enc(coalesce(v.webflow_slug, space))
             || case when c.email is not null then '&email=' || public.form_enc(c.email) else '' end;
  price := case when coalesce(v.country, c.country, '') <> ''
                     and coalesce((public.pricing_for(coalesce(v.country, c.country))->>'ready')::boolean, false)
                then public.verified_price_words(coalesce(v.country, c.country))
                else 'around a day pass a month' end;

  subj := t.subject; body := t.body;
  subj := replace(subj, '{space}', space);
  body := replace(body, '{first_name}', first_name);
  body := replace(body, '{name}', coalesce(nullif(trim(c.person_name), ''), 'there'));
  body := replace(body, '{space}', space);
  body := replace(body, '{city}', city);
  body := replace(body, '{page_link}', coalesce(page_link, 'https://www.nomadwise.io'));
  body := replace(body, '{claim_link}', claim_link);
  body := replace(body, '{price_words}', price);
  body := replace(body, '{unsubscribe_link}', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
  body := replace(body, '{signoff}', E'Jonathan\nNomadwise, https://www.nomadwise.io');
  return jsonb_build_object('subject', subj, 'body', body, 'to', c.email,
                            'page_link', page_link, 'claim_link', claim_link,
                            'stream', t.stream);
end $$;
revoke all on function public.admin_outreach_preview(uuid, text) from public, anon;
grant execute on function public.admin_outreach_preview(uuid, text) to authenticated;

-- Send. The founder has read the words; this checks the guard rails,
-- posts to Postmark, logs the message and moves the stage on.
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
      'MessageStream', coalesce(t.stream, 'outbound'),
      'Tag', 'outreach');
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

-- A list of contacts in one go: the inbox backlog, or later a list of
-- prospects. The app sends what is on the clipboard, so people's names
-- and addresses never sit in the code repository. Each row is the same
-- shape outreach_upsert() takes, plus our_reply / our_reply_at for an
-- answer we already gave. Rows already filed are left as they are.
create or replace function public.admin_outreach_import(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r    jsonb;
  cid  uuid;
  ts   timestamptz;
  n    integer := 0;
  bad  integer := 0;
  why  text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if jsonb_typeof(p) is distinct from 'array' then
    raise exception 'That is not a list of contacts.';
  end if;
  if jsonb_array_length(p) > 2000 then
    raise exception 'At most 2,000 contacts at a time.';
  end if;
  for r in select value from jsonb_array_elements(p) loop
    begin
      cid := public.outreach_upsert(r - 'our_reply' - 'our_reply_at');
      if nullif(r->>'our_reply', '') is not null then
        ts := coalesce(nullif(r->>'our_reply_at', '')::timestamptz, now());
        insert into public.outreach_messages (contact_id, direction, body, at, source_ref, sent_by)
        values (cid, 'out', left(r->>'our_reply', 4000), ts,
                case when nullif(r->>'source_ref', '') is not null
                     then 'out:' || (r->>'source_ref') end, 'inbox')
        on conflict (source_ref) where source_ref is not null do nothing;
        update public.space_contacts
           set last_out_at = greatest(coalesce(last_out_at, ts), ts)
         where id = cid;
      end if;
      n := n + 1;
    exception when others then
      bad := bad + 1;
      why := coalesce(why, sqlerrm);
    end;
  end loop;
  return jsonb_build_object('filed', n, 'skipped', bad, 'first_problem', why);
end $$;
revoke all on function public.admin_outreach_import(jsonb) from public, anon;
grant execute on function public.admin_outreach_import(jsonb) to authenticated;

create or replace function public.admin_outreach_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  delete from public.space_contacts where id = p_id;
end $$;
revoke all on function public.admin_outreach_delete(uuid) from public, anon;
grant execute on function public.admin_outreach_delete(uuid) to authenticated;
