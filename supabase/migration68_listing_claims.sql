-- ============================================================
-- Migration 68: claiming a listing.
-- (Applied automatically by the build; nothing to paste.)
--
-- An owner arrives at nomadmaps.io/?claim, searches for their space,
-- says who they are, and pays. The claim is written here first and
-- the Stripe payment link carries the claim's id, so the payment can
-- never arrive without us knowing whose it is.
--
-- Two shapes of claim:
--   * the space is already in the directory -> venue_id is set;
--   * it is not -> the space's details (from Google Places, so the
--     place id, coordinates and address are real) sit on the claim
--     and the venue row is only created once the money has landed.
--     Nothing an unpaid stranger types reaches the venues table.
--
-- scripts/stripe_sync.py calls claim_paid() when it sees the payment.
-- That makes the listing Verified, drops a brand-new space into the
-- website queue for same-day review, and pings the phone.
-- ============================================================

create table if not exists public.listing_claims (
  id                uuid primary key default gen_random_uuid(),
  venue_id          uuid references public.venues(id) on delete set null,
  is_new_space      boolean not null default false,

  -- who is paying
  owner_name        text not null check (char_length(owner_name) between 2 and 120),
  owner_email       text not null check (position('@' in owner_email) > 1
                                         and char_length(owner_email) <= 200),
  owner_phone       text check (char_length(owner_phone) <= 60),
  owner_role        text check (char_length(owner_role) <= 80),
  -- where booking requests should go (defaults to owner_email)
  enquiry_email     text check (char_length(enquiry_email) <= 200),

  -- the space, as typed or as Google gave it (new spaces only)
  space_name        text check (char_length(space_name) <= 200),
  space_type        text,
  space_address     text check (char_length(space_address) <= 300),
  space_city        text check (char_length(space_city) <= 120),
  space_country     text check (char_length(space_country) <= 120),
  space_website     text check (char_length(space_website) <= 300),
  space_place_id    text,
  space_lat         double precision,
  space_lng         double precision,
  note              text check (char_length(note) <= 2000),

  status            text not null default 'started'
                    check (status in ('started','paid','abandoned')),
  created_at        timestamptz not null default now(),
  paid_at           timestamptz
);

create index if not exists idx_listing_claims_status
  on public.listing_claims(status, created_at desc);
create index if not exists idx_listing_claims_email
  on public.listing_claims(owner_email, created_at desc);

alter table public.listing_claims enable row level security;

-- Nobody reads or writes this table directly; the form goes through
-- start_claim() and the founders read it as admins.
drop policy if exists "listing_claims admin" on public.listing_claims;
create policy "listing_claims admin" on public.listing_claims
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------------
-- Searching the directory from the public claim form. A narrow view:
-- the name, where it is, whether it already has a page, and whether
-- it is already Verified. Nothing else about the venue is exposed.
-- ------------------------------------------------------------------
create or replace function public.claim_search(p_query text)
returns table (
  id uuid, name text, city text, neighbourhood text, country text,
  webflow_slug text, on_site boolean, already_verified boolean)
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.city, v.neighbourhood, v.country, v.webflow_slug,
         v.webflow_cms_id is not null,
         v.listing_tier = 'verified'
    from public.venues v
   where char_length(trim(p_query)) >= 2
     and v.name ilike '%' || trim(p_query) || '%'
     and coalesce(v.website_status, '') <> 'retired'
     and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
   order by (v.webflow_cms_id is not null) desc, v.name
   limit 25;
$$;
grant execute on function public.claim_search(text) to anon, authenticated;

-- ------------------------------------------------------------------
-- Starting a claim. Returns the claim id, which the app puts into the
-- Stripe payment link as client_reference_id.
-- ------------------------------------------------------------------
create or replace function public.start_claim(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c_id  uuid;
  v     public.venues%rowtype;
  v_id  uuid;
  em    text := lower(trim(coalesce(p->>'owner_email', '')));
  nm    text := trim(coalesce(p->>'owner_name', ''));
  label text;
begin
  if position('@' in em) < 2 or char_length(em) > 200 then
    raise exception 'A working email address is needed.';
  end if;
  if char_length(nm) < 2 then
    raise exception 'Your name is needed.';
  end if;

  -- Gentle limits, the same idea as the booking form.
  if (select count(*) from public.listing_claims
       where owner_email = em and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Too many attempts from this address; try again later.';
  end if;
  if (select count(*) from public.listing_claims
       where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'We are busy right now; please try again in a few minutes.';
  end if;

  v_id := nullif(trim(coalesce(p->>'venue_id', '')), '')::uuid;
  if v_id is not null then
    select * into v from public.venues where id = v_id;
    if not found then
      raise exception 'That listing could not be found.';
    end if;
    if v.listing_tier = 'verified' then
      raise exception 'This listing is already Verified. Email hello@nomadwise.io and we will sort it out.';
    end if;
  elsif char_length(trim(coalesce(p->>'space_name', ''))) < 2 then
    raise exception 'The name of your space is needed.';
  end if;

  insert into public.listing_claims (
    venue_id, is_new_space, owner_name, owner_email, owner_phone, owner_role,
    enquiry_email, space_name, space_type, space_address, space_city,
    space_country, space_website, space_place_id, space_lat, space_lng, note)
  values (
    v_id,
    v_id is null,
    left(nm, 120),
    em,
    nullif(left(trim(coalesce(p->>'owner_phone', '')), 60), ''),
    nullif(left(trim(coalesce(p->>'owner_role', '')), 80), ''),
    nullif(lower(left(trim(coalesce(p->>'enquiry_email', '')), 200)), ''),
    coalesce(nullif(left(trim(coalesce(p->>'space_name', '')), 200), ''), v.name),
    case when lower(coalesce(p->>'space_type', '')) = 'cafe' then 'cafe' else 'coworking' end,
    nullif(left(trim(coalesce(p->>'space_address', '')), 300), ''),
    nullif(left(trim(coalesce(p->>'space_city', '')), 120), ''),
    nullif(left(trim(coalesce(p->>'space_country', '')), 120), ''),
    nullif(left(trim(coalesce(p->>'space_website', '')), 300), ''),
    nullif(trim(coalesce(p->>'space_place_id', '')), ''),
    (nullif(trim(coalesce(p->>'space_lat', '')), ''))::double precision,
    (nullif(trim(coalesce(p->>'space_lng', '')), ''))::double precision,
    nullif(left(trim(coalesce(p->>'note', '')), 2000), ''))
  returning id into c_id;

  label := coalesce(nullif(trim(coalesce(p->>'space_name', '')), ''), v.name, nm);
  perform public.notify_phone(
    'Claim started',
    label || ' is on the payment page' ||
      case when v_id is null then ' (new space)' else '' end,
    'eyes');

  return jsonb_build_object('claim_id', c_id, 'venue_id', v_id);
end $$;
grant execute on function public.start_claim(jsonb) to anon, authenticated;

-- ------------------------------------------------------------------
-- The money landed. Called by scripts/stripe_sync.py with the service
-- key. Finds or creates the venue, sets the Verified plan from the
-- order, asks the sync to rewrite the page, and pings the phone.
-- Returns the venue id and name so the script can record the order.
-- ------------------------------------------------------------------
create or replace function public.claim_paid(p_claim uuid, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      public.listing_claims%rowtype;
  v_id   uuid;
  v_name text;
  fresh  boolean := false;
  again  boolean := false;
  paid   date := coalesce((p_order->>'paid_at')::date, current_date);
  renews date := coalesce((p_order->>'renews_at')::date,
                          (paid + interval '1 year')::date);
begin
  select * into c from public.listing_claims where id = p_claim;
  if not found then
    return null;
  end if;

  -- Safe to call twice: a claim already settled is re-answered with the
  -- same venue and no second phone ping.
  again := c.status = 'paid';
  v_id := c.venue_id;

  -- A space Google already knows, that we already hold, is reused
  -- rather than duplicated.
  if v_id is null and c.space_place_id is not null then
    select id into v_id from public.venues where google_place_id = c.space_place_id;
  end if;

  if v_id is null then
    insert into public.venues (
      name, type, city, country, website, google_place_id, lat, lng,
      status, website_status)
    values (
      coalesce(nullif(c.space_name, ''), 'Unnamed space'),
      coalesce(nullif(c.space_type, ''), 'coworking'),
      coalesce(nullif(c.space_city, ''), 'Unknown'),
      nullif(c.space_country, ''),
      nullif(c.space_website, ''),
      c.space_place_id,
      c.space_lat,
      c.space_lng,
      'verified',
      'queued')
    returning id into v_id;
    fresh := true;
  end if;

  update public.venues set
    listing_tier              = 'verified',
    listing_owner_name        = coalesce(c.owner_name, listing_owner_name),
    listing_owner_email       = coalesce(c.owner_email, listing_owner_email),
    listing_enquiry_email     = coalesce(nullif(c.enquiry_email, ''),
                                         c.owner_email, listing_enquiry_email),
    listing_paid_at           = paid,
    listing_renews_at         = renews,
    listing_notes             = concat_ws(E'\n',
                                  nullif(listing_notes, ''),
                                  'Claimed by ' || c.owner_name ||
                                    coalesce(' (' || nullif(c.owner_role, '') || ')', '') ||
                                    ' on ' || to_char(now(), 'DD Mon YYYY') ||
                                    coalesce('. Phone ' || nullif(c.owner_phone, ''), ''),
                                  nullif(c.note, '')),
    stripe_customer_id        = coalesce(nullif(p_order->>'customer_id', ''), stripe_customer_id),
    stripe_subscription_id    = coalesce(nullif(p_order->>'subscription_id', ''), stripe_subscription_id),
    listing_sync_requested_at = now(),
    listing_synced_at         = null,
    listing_sync_error        = null,
    -- A paid space with no page yet goes into the queue for review.
    website_status            = case when webflow_cms_id is null
                                      and coalesce(website_status, 'not_on_site')
                                          in ('not_on_site', 'removed')
                                     then 'queued' else website_status end,
    website_dismissed_at      = case when webflow_cms_id is null
                                     then null else website_dismissed_at end
  where id = v_id
  returning name into v_name;

  update public.listing_claims
     set status = 'paid', paid_at = now(), venue_id = v_id
   where id = p_claim;

  if not again then
    perform public.notify_phone(
      case when fresh then 'PAID — new space, publish today'
           else 'PAID — Verified listing' end,
      coalesce(v_name, c.space_name, 'A space') || ' paid EUR 99. ' ||
        case when fresh then 'It is in the queue: review and approve it today.'
             else 'The badge goes on at the next push.' end,
      'moneybag');
  end if;

  return jsonb_build_object('venue_id', v_id, 'name', v_name, 'new_space', fresh);
end $$;

-- Founders can mark a stale claim as abandoned from the control centre.
create or replace function public.abandon_claim(p_claim uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  update public.listing_claims set status = 'abandoned'
   where id = p_claim and status = 'started';
end $$;
grant execute on function public.abandon_claim(uuid) to authenticated;
