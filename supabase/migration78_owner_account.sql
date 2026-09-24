-- ============================================================
-- Migration 78: the Owner account.
-- (Applied automatically by the build; nothing to paste.)
--
-- What an owner sees is "Owner account" and "Manage my listing"
-- (never "members area"). It lives in the app at nomadmaps.io/?owner.
-- An owner signs in with the email recorded on their space by an
-- approved claim (listing_owner_email); an email link or Google, no
-- password. They edit a DRAFT of their page: description, prices,
-- hours, the work-friendly facts, website, Instagram, WhatsApp,
-- photos, and (Verified only) the message that replaces the advert
-- slot. Nothing goes live until a founder reads it in the control
-- centre and puts it on the page; declined drafts carry a note back.
-- Applied content is kept on the venue in owner_content and the
-- sync writes it to Webflow. No analytics, no perks (decided with
-- Leonie, 21 and 24 Sep 2026).
-- ============================================================

alter table public.venues
  add column if not exists owner_content    jsonb,
  add column if not exists owner_content_at timestamptz;

create table if not exists public.owner_drafts (
  id            uuid primary key default gen_random_uuid(),
  venue_id      uuid not null references public.venues(id) on delete cascade,
  owner_email   text not null,
  draft         jsonb not null default '{}'::jsonb,
  status        text not null default 'draft'
                check (status in ('draft','submitted','applied','declined')),
  submitted_at  timestamptz,
  reviewed_at   timestamptz,
  review_note   text check (char_length(review_note) <= 1000),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_owner_drafts_venue on public.owner_drafts(venue_id);
create index if not exists idx_owner_drafts_status on public.owner_drafts(status);
alter table public.owner_drafts enable row level security;
-- No direct table access: every read and write goes through the
-- functions below, which check who is asking.

-- Owner photos: a public bucket, each owner in their own folder.
insert into storage.buckets (id, name, public)
values ('owner-photos', 'owner-photos', true)
on conflict (id) do nothing;

drop policy if exists "owner photos upload own" on storage.objects;
create policy "owner photos upload own" on storage.objects
  for insert with check (
    bucket_id = 'owner-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
drop policy if exists "owner photos read" on storage.objects;
create policy "owner photos read" on storage.objects
  for select using (bucket_id = 'owner-photos');

-- ------------------------------------------------------------------
-- Who is asking, by email. auth.email() is the signed-in address.
-- ------------------------------------------------------------------
create or replace function public.owner_email()
returns text language sql stable as $$
  select lower(nullif(trim(coalesce(auth.jwt() ->> 'email', '')), ''));
$$;

-- ------------------------------------------------------------------
-- The spaces this owner may manage, with the current draft if any.
-- ------------------------------------------------------------------
create or replace function public.owner_venues()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em  text := public.owner_email();
  out jsonb;
begin
  if em is null then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', v.id,
      'name', v.name,
      'type', v.type,
      'city', v.city,
      'neighbourhood', v.neighbourhood,
      'country', v.country,
      'webflow_slug', v.webflow_slug,
      'website_status', v.website_status,
      'listing_tier', v.listing_tier,
      'listing_paid_at', v.listing_paid_at,
      'listing_renews_at', v.listing_renews_at,
      'listing_enquiry_email', v.listing_enquiry_email,
      'website', v.website,
      'instagram', v.instagram,
      'opening_hours', v.opening_hours,
      'wifi_speed_mbps', v.wifi_speed_mbps,
      'google_rating_snapshot', v.google_rating_snapshot,
      'google_reviews_snapshot', v.google_reviews_snapshot,
      'facts', jsonb_build_object(
        'laptops_allowed', v.laptops_allowed,
        'power_outlets', v.power_outlets,
        'aircon', v.aircon,
        'comfortable_seating', v.comfortable_seating,
        'cozy', v.cozy,
        'quiet_space', v.quiet_space,
        'good_for_calls', v.good_for_calls,
        'call_room', v.call_room,
        'monitor', v.monitor,
        'office_chairs', v.office_chairs,
        'access_24h', v.access_24h),
      'google_photos', (select coalesce(jsonb_agg(value), '[]'::jsonb)
                          from jsonb_each_text(coalesce(v.google_photo_urls, '{}'::jsonb))),
      'owner_content', v.owner_content,
      'owner_content_at', v.owner_content_at,
      'draft', (select jsonb_build_object(
                  'id', d.id, 'draft', d.draft, 'status', d.status,
                  'submitted_at', d.submitted_at, 'reviewed_at', d.reviewed_at,
                  'review_note', d.review_note, 'updated_at', d.updated_at)
                  from public.owner_drafts d
                 where d.venue_id = v.id
                 order by d.updated_at desc limit 1)
    ) order by v.name), '[]'::jsonb)
    into out
    from public.venues v
   where lower(v.listing_owner_email) = em;
  return out;
end $$;
grant execute on function public.owner_venues() to authenticated;

-- ------------------------------------------------------------------
-- Save the draft (and submit it for review when asked). One open
-- draft per space: an applied or declined one starts a new draft.
-- ------------------------------------------------------------------
create or replace function public.owner_save_draft(
  p_venue uuid, p_draft jsonb, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em     text := public.owner_email();
  v_name text;
  d      public.owner_drafts%rowtype;
  clean  jsonb;
begin
  if em is null then
    raise exception 'Please sign in.';
  end if;
  select name into v_name from public.venues
   where id = p_venue and lower(listing_owner_email) = em;
  if not found then
    raise exception 'This space is not on your account.';
  end if;
  if pg_column_size(p_draft) > 60000 then
    raise exception 'That is too much text; please shorten it.';
  end if;

  -- Keep only the keys the editor knows, trimmed to sane lengths.
  clean := jsonb_strip_nulls(jsonb_build_object(
    'description', left(coalesce(p_draft->>'description', ''), 3000),
    'prices', jsonb_build_object(
        'day',    left(coalesce(p_draft#>>'{prices,day}', ''), 60),
        'week',   left(coalesce(p_draft#>>'{prices,week}', ''), 60),
        'month',  left(coalesce(p_draft#>>'{prices,month}', ''), 60),
        'coffee', left(coalesce(p_draft#>>'{prices,coffee}', ''), 60)),
    'hours', coalesce(p_draft->'hours', '{}'::jsonb),
    'facts', coalesce(p_draft->'facts', '{}'::jsonb),
    'website', left(coalesce(p_draft->>'website', ''), 300),
    'instagram', left(coalesce(p_draft->>'instagram', ''), 300),
    'whatsapp', left(coalesce(p_draft->>'whatsapp', ''), 60),
    'enquiry_email', lower(left(coalesce(p_draft->>'enquiry_email', ''), 200)),
    'photos', coalesce(p_draft->'photos', '[]'::jsonb),
    'mention', case when p_draft ? 'mention' then jsonb_build_object(
        'kind',  left(coalesce(p_draft#>>'{mention,kind}', ''), 20),
        'title', left(coalesce(p_draft#>>'{mention,title}', ''), 90),
        'body',  left(coalesce(p_draft#>>'{mention,body}', ''), 300),
        'cta',   left(coalesce(p_draft#>>'{mention,cta}', ''), 40),
        'url',   left(coalesce(p_draft#>>'{mention,url}', ''), 300))
      else null end));

  select * into d from public.owner_drafts
   where venue_id = p_venue and status in ('draft', 'submitted')
   order by updated_at desc limit 1;

  if found then
    update public.owner_drafts
       set draft = clean,
           owner_email = em,
           status = case when p_submit then 'submitted' else 'draft' end,
           submitted_at = case when p_submit then now() else submitted_at end,
           updated_at = now()
     where id = d.id
     returning * into d;
  else
    insert into public.owner_drafts (venue_id, owner_email, draft, status, submitted_at)
    values (p_venue, em, clean,
            case when p_submit then 'submitted' else 'draft' end,
            case when p_submit then now() else null end)
    returning * into d;
  end if;

  if p_submit then
    perform public.notify_phone(
      'Owner changes to review',
      coalesce(v_name, 'A space') || ': the owner submitted changes to their '
        'page. Read them in Owner changes and put them on, or send them back.',
      'pencil');
  end if;

  return jsonb_build_object('id', d.id, 'status', d.status,
                            'submitted_at', d.submitted_at);
end $$;
grant execute on function public.owner_save_draft(uuid, jsonb, boolean) to authenticated;

-- ------------------------------------------------------------------
-- Control centre: the drafts waiting, with the space beside them.
-- ------------------------------------------------------------------
create or replace function public.owner_drafts_to_review()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id,
      'venue_id', d.venue_id,
      'owner_email', d.owner_email,
      'draft', d.draft,
      'status', d.status,
      'submitted_at', d.submitted_at,
      'venue', jsonb_build_object(
        'name', v.name, 'city', v.city, 'country', v.country,
        'type', v.type, 'webflow_slug', v.webflow_slug,
        'listing_tier', v.listing_tier, 'website', v.website,
        'instagram', v.instagram, 'opening_hours', v.opening_hours,
        'owner_content', v.owner_content,
        'facts', jsonb_build_object(
          'laptops_allowed', v.laptops_allowed,
          'power_outlets', v.power_outlets, 'aircon', v.aircon,
          'comfortable_seating', v.comfortable_seating, 'cozy', v.cozy,
          'quiet_space', v.quiet_space, 'good_for_calls', v.good_for_calls,
          'call_room', v.call_room, 'monitor', v.monitor,
          'office_chairs', v.office_chairs, 'access_24h', v.access_24h))
    ) order by d.submitted_at asc), '[]'::jsonb)
    from public.owner_drafts d
    join public.venues v on v.id = d.venue_id
   where d.status = 'submitted');
end $$;
grant execute on function public.owner_drafts_to_review() to authenticated;

-- ------------------------------------------------------------------
-- Put it on the page: copy the draft onto the venue and ask the
-- sync to write it to Webflow. Facts and hours also go into the
-- columns the rest of the app and the site already read.
-- ------------------------------------------------------------------
create or replace function public.owner_apply_draft(p_draft uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d      public.owner_drafts%rowtype;
  f      jsonb;
  h      jsonb;
  v_name text;
  tier   text;
  m      jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select * into d from public.owner_drafts where id = p_draft;
  if not found or d.status <> 'submitted' then
    raise exception 'This draft is not waiting for review.';
  end if;
  f := coalesce(d.draft->'facts', '{}'::jsonb);
  h := coalesce(d.draft->'hours', '{}'::jsonb);
  select listing_tier into tier from public.venues where id = d.venue_id;
  -- The advert-slot message is a Verified benefit; a free page's draft
  -- may carry one from before a lapse, and it is simply not applied.
  m := case when tier = 'verified' then d.draft->'mention' else null end;

  update public.venues set
    owner_content    = jsonb_strip_nulls(jsonb_build_object(
                         'description', nullif(d.draft->>'description', ''),
                         'prices', d.draft->'prices',
                         'photos', d.draft->'photos',
                         'whatsapp', nullif(d.draft->>'whatsapp', ''),
                         'mention', m)),
    owner_content_at = now(),
    website          = coalesce(nullif(d.draft->>'website', ''), website),
    instagram        = coalesce(nullif(d.draft->>'instagram', ''), instagram),
    listing_enquiry_email = coalesce(nullif(d.draft->>'enquiry_email', ''),
                                     listing_enquiry_email),
    opening_hours    = case when h <> '{}'::jsonb then h else opening_hours end,
    website_photos   = case when jsonb_array_length(coalesce(d.draft->'photos', '[]'::jsonb)) > 0
                            then d.draft->'photos' else website_photos end,
    laptops_allowed     = coalesce((f->>'laptops_allowed')::boolean, laptops_allowed),
    power_outlets       = coalesce((f->>'power_outlets')::boolean, power_outlets),
    aircon              = coalesce((f->>'aircon')::boolean, aircon),
    comfortable_seating = coalesce((f->>'comfortable_seating')::boolean, comfortable_seating),
    cozy                = coalesce((f->>'cozy')::boolean, cozy),
    quiet_space         = coalesce((f->>'quiet_space')::boolean, quiet_space),
    good_for_calls      = coalesce((f->>'good_for_calls')::boolean, good_for_calls),
    call_room           = coalesce((f->>'call_room')::boolean, call_room),
    monitor             = coalesce((f->>'monitor')::boolean, monitor),
    office_chairs       = coalesce((f->>'office_chairs')::boolean, office_chairs),
    access_24h          = coalesce((f->>'access_24h')::boolean, access_24h),
    listing_sync_requested_at = now(),
    listing_synced_at   = null,
    listing_sync_error  = null
  where id = d.venue_id
  returning name into v_name;

  update public.owner_drafts
     set status = 'applied', reviewed_at = now(), updated_at = now()
   where id = p_draft;

  return jsonb_build_object('venue_id', d.venue_id, 'name', v_name);
end $$;
grant execute on function public.owner_apply_draft(uuid) to authenticated;

create or replace function public.owner_decline_draft(p_draft uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  update public.owner_drafts
     set status = 'declined',
         reviewed_at = now(),
         updated_at = now(),
         review_note = nullif(left(trim(coalesce(p_note, '')), 1000), '')
   where id = p_draft and status = 'submitted';
  if not found then
    raise exception 'This draft is not waiting for review.';
  end if;
end $$;
grant execute on function public.owner_decline_draft(uuid, text) to authenticated;

-- The sync reads owner content with the listing plan fields.
-- (No schema change needed: it selects owner_content by name.)
