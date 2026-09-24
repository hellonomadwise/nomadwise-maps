-- ============================================================
-- Migration 77: the claim form's free option.
-- (Applied automatically by the build; nothing to paste.)
--
-- The plan always had two doors on the claim page: a free listing
-- with an owner account, and Verified. Until now only Verified was
-- built, so an owner who just wanted to be listed and put their
-- facts right had no door. A free claim is the same form without the
-- payment step. It lands as 'free_pending'; the control centre shows
-- it next to the paid claims with the same ownership check; Approve
-- records the person as the page's owner (nothing visible changes on
-- the site, the plan stays free), and for a space not on the map yet
-- creates it and puts it in the normal publishing queue. Reject
-- leaves everything untouched. The recorded owner email is what the
-- owner account will log in with later, and who the Verified offer
-- email goes to.
-- ============================================================

alter table public.listing_claims
  add column if not exists plan text not null default 'verified'
    check (plan in ('verified', 'free'));

alter table public.listing_claims drop constraint if exists listing_claims_status_check;
alter table public.listing_claims
  add constraint listing_claims_status_check
  check (status in ('started','paid','abandoned','awaiting_approval','rejected',
                    'free_pending','free'));

-- ------------------------------------------------------------------
-- start_claim: as before, plus p->>'plan' = 'free' which skips
-- payment: the claim is created already waiting for approval.
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
  free  boolean := lower(coalesce(p->>'plan', '')) = 'free';
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
    if free and v.listing_owner_email is not null
       and lower(v.listing_owner_email) = em then
      raise exception 'This listing is already yours. Email hello@nomadwise.io for anything you need changed.';
    end if;
  elsif char_length(trim(coalesce(p->>'space_name', ''))) < 2 then
    raise exception 'The name of your space is needed.';
  end if;

  insert into public.listing_claims (
    venue_id, is_new_space, owner_name, owner_email, owner_phone, owner_role,
    enquiry_email, space_name, space_type, space_address, space_city,
    space_country, space_website, space_instagram, space_place_id,
    space_lat, space_lng, note, plan, status)
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
    nullif(left(trim(coalesce(p->>'note', '')), 2000), ''),
    case when free then 'free' else 'verified' end,
    case when free then 'free_pending' else 'started' end)
  returning id into c_id;

  label := coalesce(nullif(trim(coalesce(p->>'space_name', '')), ''), v.name, nm);
  if free then
    perform public.notify_phone(
      'Free claim, approve?',
      nm || ' claims ' || label ||
        case when v_id is null then ' (new space)' else '' end ||
        ' for free. Approve or reject it in Paid listings.',
      'eyes');
  else
    perform public.notify_phone(
      'Claim started',
      label || ' is on the payment page' ||
        case when v_id is null then ' (new space)' else '' end,
      'eyes');
  end if;

  return jsonb_build_object('claim_id', c_id, 'venue_id', v_id,
                            'plan', case when free then 'free' else 'verified' end);
end $$;
grant execute on function public.start_claim(jsonb) to anon, authenticated;

-- ------------------------------------------------------------------
-- Approve: a paid claim becomes Verified as before; a free claim
-- records the owner and, for a new space, creates it in the queue.
-- ------------------------------------------------------------------
create or replace function public.approve_claim(p_claim uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      public.listing_claims%rowtype;
  v_id   uuid;
  v_name text;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select * into c from public.listing_claims where id = p_claim;
  if not found then
    raise exception 'That claim could not be found.';
  end if;

  if c.status = 'awaiting_approval' then
    if c.venue_id is null then
      raise exception 'This claim has no space attached.';
    end if;
    update public.listing_claims
       set status = 'paid', approved_at = now()
     where id = p_claim;
    v_name := public.apply_claim(p_claim);
    return jsonb_build_object('venue_id', c.venue_id, 'name', v_name,
                              'plan', 'verified');
  end if;

  if c.status <> 'free_pending' then
    raise exception 'This claim is not waiting for approval (it is %).', c.status;
  end if;

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
  end if;

  -- Owner on record; the plan stays free and the page keeps its
  -- content. The two optional links fill empty fields only.
  update public.venues set
    listing_owner_name   = coalesce(c.owner_name, listing_owner_name),
    listing_owner_email  = coalesce(c.owner_email, listing_owner_email),
    listing_notes        = concat_ws(E'\n',
                             nullif(listing_notes, ''),
                             'Free claim by ' || c.owner_name ||
                               coalesce(' (' || nullif(c.owner_role, '') || ')', '') ||
                               ' on ' || to_char(now(), 'DD Mon YYYY') ||
                               coalesce('. Phone ' || nullif(c.owner_phone, ''), ''),
                             nullif(c.note, '')),
    website              = coalesce(nullif(website, ''), c.space_website),
    instagram            = coalesce(nullif(instagram, ''), c.space_instagram)
  where id = v_id
  returning name into v_name;

  update public.listing_claims
     set status = 'free', approved_at = now(), venue_id = v_id
   where id = p_claim;

  return jsonb_build_object('venue_id', v_id, 'name', v_name, 'plan', 'free');
end $$;
grant execute on function public.approve_claim(uuid) to authenticated;

-- ------------------------------------------------------------------
-- Reject: paid or free, the page is untouched.
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
   where id = p_claim and status in ('awaiting_approval', 'free_pending');
  if not found then
    raise exception 'This claim is not waiting for approval.';
  end if;
end $$;
grant execute on function public.reject_claim(uuid, text) to authenticated;
