-- ============================================================
-- Migration 71: two optional fields on the claim form, and an
-- approval hold on paid claims for pages already on the site.
-- (Applied automatically by the build; nothing to paste.)
--
-- 1. Website and Instagram are asked for on the "About you" step,
--    optional, for every claim. They ride on the claim and are copied
--    to the venue only when the claim is applied, and only into empty
--    fields, so nothing an owner types overwrites what is on the page
--    without a look.
--
-- 2. Until now claim_paid() made a listing Verified the moment the
--    payment landed. For a space that is already on the site that
--    meant a wrong or hostile claim on someone else's page went live
--    (badge, owner details, booking inbox) until undone. Now such a
--    claim lands as 'awaiting_approval' and touches nothing; the
--    control centre shows it with Approve and Reject. A brand-new
--    space still goes straight into the publishing queue, because the
--    queue review is its approval and nothing is live before it.
-- ============================================================

alter table public.listing_claims
  add column if not exists space_instagram        text check (char_length(space_instagram) <= 300),
  add column if not exists order_json             jsonb,
  add column if not exists approved_at            timestamptz,
  add column if not exists rejected_at            timestamptz,
  add column if not exists reject_reason          text check (char_length(reject_reason) <= 500);

alter table public.listing_claims drop constraint if exists listing_claims_status_check;
alter table public.listing_claims
  add constraint listing_claims_status_check
  check (status in ('started','paid','abandoned','awaiting_approval','rejected'));

-- ------------------------------------------------------------------
-- start_claim: as before, plus website and Instagram for any claim.
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
  site  text := nullif(left(trim(coalesce(p->>'space_website', '')), 300), '');
  insta text := nullif(left(trim(coalesce(p->>'space_instagram', '')), 300), '');
begin
  if position('@' in em) < 2 or char_length(em) > 200 then
    raise exception 'A working email address is needed.';
  end if;
  if char_length(nm) < 2 then
    raise exception 'Your name is needed.';
  end if;

  if (select count(*) from public.listing_claims
       where owner_email = em and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Too many attempts from this address; try again later.';
  end if;
  if (select count(*) from public.listing_claims
       where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'We are busy right now; please try again in a few minutes.';
  end if;

  -- Tidy the two optional links: "mysite.com" becomes a real address,
  -- "@myspace" becomes the Instagram page.
  if site is not null and site !~* '^https?://' then
    site := 'https://' || site;
  end if;
  if insta is not null and insta !~* '^https?://' then
    insta := 'https://www.instagram.com/' || ltrim(insta, '@') || '/';
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
    space_country, space_website, space_instagram, space_place_id,
    space_lat, space_lng, note)
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
    site,
    insta,
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
-- Applying a claim to its venue: the one place the Verified fields
-- are written. Used by claim_paid() for a brand-new space and by
-- approve_claim() for an existing page. Not callable from outside.
-- ------------------------------------------------------------------
create or replace function public.apply_claim(p_claim uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  c      public.listing_claims%rowtype;
  o      jsonb;
  v_name text;
  paid   date;
  renews date;
begin
  select * into c from public.listing_claims where id = p_claim;
  if not found or c.venue_id is null then
    return null;
  end if;
  o := coalesce(c.order_json, '{}'::jsonb);
  paid := coalesce((o->>'paid_at')::date, c.paid_at::date, current_date);
  renews := coalesce((o->>'renews_at')::date, (paid + interval '1 year')::date);

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
                                    ' on ' || to_char(coalesce(c.paid_at, now()), 'DD Mon YYYY') ||
                                    coalesce('. Phone ' || nullif(c.owner_phone, ''), ''),
                                  nullif(c.note, '')),
    -- The two optional links fill empty fields only; a page's existing
    -- website or Instagram is never overwritten by a form.
    website                   = coalesce(nullif(website, ''), c.space_website),
    instagram                 = coalesce(nullif(instagram, ''), c.space_instagram),
    stripe_customer_id        = coalesce(nullif(o->>'customer_id', ''), stripe_customer_id),
    stripe_subscription_id    = coalesce(nullif(o->>'subscription_id', ''), stripe_subscription_id),
    listing_sync_requested_at = now(),
    listing_synced_at         = null,
    listing_sync_error        = null,
    website_status            = case when webflow_cms_id is null
                                      and coalesce(website_status, 'not_on_site')
                                          in ('not_on_site', 'removed')
                                     then 'queued' else website_status end,
    website_dismissed_at      = case when webflow_cms_id is null
                                     then null else website_dismissed_at end
  where id = c.venue_id
  returning name into v_name;

  return v_name;
end $$;
revoke all on function public.apply_claim(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------
-- The money landed. A brand-new space is created and queued as before.
-- A space already in the directory is held for approval instead.
-- ------------------------------------------------------------------
create or replace function public.claim_paid(p_claim uuid, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      public.listing_claims%rowtype;
  v_id   uuid;
  v_name text;
  fresh  boolean := false;
  again  boolean := false;
  held   boolean := false;
begin
  select * into c from public.listing_claims where id = p_claim;
  if not found then
    return null;
  end if;

  -- Safe to call twice: a settled or held claim is re-answered with the
  -- same venue and no second phone ping.
  again := c.status in ('paid', 'awaiting_approval', 'rejected');
  v_id := c.venue_id;

  if v_id is null and c.space_place_id is not null then
    select id into v_id from public.venues where google_place_id = c.space_place_id;
  end if;

  if v_id is null then
    insert into public.venues (
      name, type, city, country, website, instagram, google_place_id, lat, lng,
      status, website_status)
    values (
      coalesce(nullif(c.space_name, ''), 'Unnamed space'),
      coalesce(nullif(c.space_type, ''), 'coworking'),
      coalesce(nullif(c.space_city, ''), 'Unknown'),
      nullif(c.space_country, ''),
      nullif(c.space_website, ''),
      nullif(c.space_instagram, ''),
      c.space_place_id,
      c.space_lat,
      c.space_lng,
      'verified',
      'queued')
    returning id into v_id;
    fresh := true;
  end if;

  if again then
    select name into v_name from public.venues where id = v_id;
    return jsonb_build_object('venue_id', v_id, 'name', v_name,
                              'new_space', false,
                              'held', c.status = 'awaiting_approval');
  end if;

  -- Keep the order on the claim so approval can copy it to the venue.
  update public.listing_claims
     set order_json = coalesce(p_order, '{}'::jsonb),
         paid_at = coalesce(paid_at, now()),
         venue_id = v_id
   where id = p_claim;

  if fresh then
    update public.listing_claims set status = 'paid' where id = p_claim;
    v_name := public.apply_claim(p_claim);
    perform public.notify_phone(
      'PAID, new space in the queue',
      coalesce(v_name, c.space_name, 'A space') || ' paid EUR 99. ' ||
        'It is in the publishing queue: review it and approve it.',
      'moneybag');
  else
    held := true;
    update public.listing_claims set status = 'awaiting_approval' where id = p_claim;
    select name into v_name from public.venues where id = v_id;
    perform public.notify_phone(
      'PAID, approve the claim',
      coalesce(v_name, c.space_name, 'A space') || ' paid EUR 99 through the claim form. ' ||
        'Nothing changes on the page until you approve it in Paid listings.',
      'moneybag');
  end if;

  return jsonb_build_object('venue_id', v_id, 'name', v_name,
                            'new_space', fresh, 'held', held);
end $$;

-- ------------------------------------------------------------------
-- Approve: the founders looked, it is theirs, make it Verified.
-- ------------------------------------------------------------------
create or replace function public.approve_claim(p_claim uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      public.listing_claims%rowtype;
  v_name text;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select * into c from public.listing_claims where id = p_claim;
  if not found then
    raise exception 'That claim could not be found.';
  end if;
  if c.status <> 'awaiting_approval' then
    raise exception 'This claim is not waiting for approval (it is %).', c.status;
  end if;
  if c.venue_id is null then
    raise exception 'This claim has no space attached.';
  end if;

  update public.listing_claims
     set status = 'paid', approved_at = now()
   where id = p_claim;
  v_name := public.apply_claim(p_claim);

  return jsonb_build_object('venue_id', c.venue_id, 'name', v_name);
end $$;
grant execute on function public.approve_claim(uuid) to authenticated;

-- ------------------------------------------------------------------
-- Reject: wrong space, someone else's business, does not fit. The
-- venue is untouched. The refund itself is one click in the Stripe
-- dashboard; the claim keeps the customer and subscription ids so it
-- is easy to find there, and the reason so a repeat is recognised.
-- ------------------------------------------------------------------
create or replace function public.reject_claim(p_claim uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  update public.listing_claims
     set status = 'rejected',
         rejected_at = now(),
         reject_reason = nullif(left(trim(coalesce(p_reason, '')), 500), '')
   where id = p_claim and status = 'awaiting_approval';
  if not found then
    raise exception 'This claim is not waiting for approval.';
  end if;
end $$;
grant execute on function public.reject_claim(uuid, text) to authenticated;
