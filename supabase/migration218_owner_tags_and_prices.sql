-- ============================================================
-- Migration 218: the Owner account can set every tag the page has,
-- and keep a full price list.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 24 Oct (CR-22, Leonie's idea):
--   * Tags. The page has six tags owners could not set: Swimming Pool,
--     No Traffic Noise, Low Background Music, Instagramable, Vegan
--     Friendly and Pass Required. They become columns on venues, like
--     the other ten, so an owner can tick or untick them and the
--     website push writes them to the page. The website push also
--     reads them back from the pages, so they start as the pages have
--     them.
--   * Prices. An owner keeps any number of prices (name, kind, price,
--     "from", a note). Saving sends each change to the founders' Price
--     check list (product_changes, source 'owner'), the same list the
--     price checks use: nothing reaches the page until a founder
--     presses Go, then the website push writes it to the Products
--     collection in Webflow.
--   * The Owner account sees its prices with their ids, and how many
--     of its price changes are still waiting.
-- Each function below is its latest version with only these additions.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

alter table public.venues
  add column if not exists swimming_pool        boolean,
  add column if not exists no_traffic_noise     boolean,
  add column if not exists low_background_music boolean,
  add column if not exists instagramable        boolean,
  add column if not exists vegan_friendly       boolean,
  add column if not exists pass_required        boolean;

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
        'access_24h', v.access_24h,
        'swimming_pool', v.swimming_pool,
        'no_traffic_noise', v.no_traffic_noise,
        'low_background_music', v.low_background_music,
        'instagramable', v.instagramable,
        'vegan_friendly', v.vegan_friendly,
        'pass_required', v.pass_required),
      'google_photos', (select coalesce(jsonb_agg(value), '[]'::jsonb)
                          from jsonb_each_text(coalesce(v.google_photo_urls, '{}'::jsonb))),
      'page_description', v.page_description,
      'owner_content', v.owner_content,
      'owner_content_at', v.owner_content_at,
      'draft', (select jsonb_build_object(
                  'id', d.id, 'draft', d.draft, 'status', d.status,
                  'submitted_at', d.submitted_at, 'reviewed_at', d.reviewed_at,
                  'review_note', d.review_note, 'updated_at', d.updated_at)
                  from public.owner_drafts d
                 where d.venue_id = v.id
                 order by d.updated_at desc limit 1)
    ) || public.owner_page_extras(v) order by v.name), '[]'::jsonb)
    into out
    from public.venues v
   where lower(v.listing_owner_email) = em;
  return out;
end $$;

create or replace function public.admin_owner_view(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select jsonb_build_object(
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
      'listing_owner_email', v.listing_owner_email,
      'claim_email', (select c.owner_email from public.listing_claims c
                       where c.venue_id = v.id
                         and c.status not in ('abandoned', 'rejected')
                       order by c.created_at desc limit 1),
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
        'access_24h', v.access_24h,
        'swimming_pool', v.swimming_pool,
        'no_traffic_noise', v.no_traffic_noise,
        'low_background_music', v.low_background_music,
        'instagramable', v.instagramable,
        'vegan_friendly', v.vegan_friendly,
        'pass_required', v.pass_required),
      'google_photos', (select coalesce(jsonb_agg(value), '[]'::jsonb)
                          from jsonb_each_text(coalesce(v.google_photo_urls, '{}'::jsonb))),
      'page_description', v.page_description,
      'owner_content', v.owner_content,
      'owner_content_at', v.owner_content_at,
      'draft', (select jsonb_build_object(
                  'id', d.id, 'draft', d.draft, 'status', d.status,
                  'submitted_at', d.submitted_at, 'reviewed_at', d.reviewed_at,
                  'review_note', d.review_note, 'updated_at', d.updated_at)
                  from public.owner_drafts d
                 where d.venue_id = v.id
                 order by d.updated_at desc limit 1))
      || public.owner_page_extras(v)
    into out
    from public.venues v
   where v.id::text = p_key or v.webflow_slug = p_key
   limit 1;
  return out;
end $$;

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
      'sent_back', (
        -- A sent-back draft is kept as it was (the owner's next save
        -- starts a new one), so it holds both our note and what they
        -- had submitted.
        select jsonb_build_object(
                 'note', x.review_note,
                 'at', x.reviewed_at,
                 'previous', x.draft)
          from public.owner_drafts x
         where x.venue_id = d.venue_id
           and x.id <> d.id
           and x.status = 'declined'
           and x.reviewed_at is not null
           and x.reviewed_at <= coalesce(d.submitted_at, now())
           -- only this round: not a note from before changes were put on
           and not exists (select 1 from public.owner_drafts a
                            where a.venue_id = d.venue_id
                              and a.status = 'applied'
                              and a.reviewed_at > x.reviewed_at)
         order by x.reviewed_at desc limit 1),
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
          'office_chairs', v.office_chairs, 'access_24h', v.access_24h,
          'swimming_pool', v.swimming_pool,
          'no_traffic_noise', v.no_traffic_noise,
          'low_background_music', v.low_background_music,
          'instagramable', v.instagramable,
          'vegan_friendly', v.vegan_friendly,
          'pass_required', v.pass_required))
    ) order by d.submitted_at asc), '[]'::jsonb)
    from public.owner_drafts d
    join public.venues v on v.id = d.venue_id
   where d.status = 'submitted');
end $$;

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
    swimming_pool       = coalesce((f->>'swimming_pool')::boolean, swimming_pool),
    no_traffic_noise    = coalesce((f->>'no_traffic_noise')::boolean, no_traffic_noise),
    low_background_music= coalesce((f->>'low_background_music')::boolean, low_background_music),
    instagramable       = coalesce((f->>'instagramable')::boolean, instagramable),
    vegan_friendly      = coalesce((f->>'vegan_friendly')::boolean, vegan_friendly),
    pass_required       = coalesce((f->>'pass_required')::boolean, pass_required),
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

create or replace function public.owner_page_extras(v public.venues)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'page_photos', coalesce(
      (select jsonb_agg(u order by ord)
         from public.venue_page_facts f,
              jsonb_array_elements_text(
                case when jsonb_typeof(f.facts -> 'photo_urls') = 'array'
                     then f.facts -> 'photo_urls' else '[]'::jsonb end)
                with ordinality as e(u, ord)
        where f.venue_id = v.id and u ~* '^https?://'),
      '[]'::jsonb),
    'page_description', coalesce(
      nullif(btrim(v.page_description), ''),
      (select nullif(btrim(f.facts ->> 'desc'), '')
         from public.venue_page_facts f where f.venue_id = v.id)),
    'google_hours', public.owner_google_hours(v.g_details),
    'page_products', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'id', p.id,
                'amount', p.amount,
                'currency', p.currency,
                'starting_from', p.starting_from,
                'details', p.details,
                'name', p.name,
                'label', coalesce(nullif(btrim(p.price_label), ''),
                                  public.product_label(p.amount, p.currency)),
                'category', p.category)
              order by p.position, p.name)
         from public.venue_products p
        where p.venue_id = v.id and p.status = 'live'),
      '[]'::jsonb),
    -- Price changes sent from the Owner account and not on the page
    -- yet (migration 218).
    'price_changes_waiting', (select count(*) from public.product_changes c
        where c.venue_id = v.id and c.source = 'owner'
          and c.status in ('proposed', 'approved', 'failed')))
$$;

-- ------------------------------------------------ owner price list

-- The Owner account's price list, as the owner left it. Compared with
-- the prices on the page: a changed one becomes an update, a new one
-- an add, one left out a remove, each waiting for a founder's Go in
-- Price check. A row is {id?, name, category, amount, currency,
-- starting_from, details}. An earlier owner change still waiting is
-- replaced; one already on its way to the page is left as it is.
create or replace function public.owner_propose_products(
  p_venue uuid, p_rows jsonb, p_currency text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em       text := public.owner_email();
  v        public.venues%rowtype;
  r        jsonb;
  pr       public.venue_products%rowtype;
  open_    public.product_changes%rowtype;
  has_open boolean;
  base     jsonb;
  fin      jsonb;
  why      text;
  keep     uuid[] := '{}';
  seen     text[] := '{}';
  cur      text := nullif(upper(btrim(coalesce(p_currency, ''))), '');
  note_    text;
  n_add    integer := 0;
  n_up     integer := 0;
  n_rm     integer := 0;
  problems jsonb := '[]'::jsonb;
begin
  if em is null then
    raise exception 'Please sign in again.';
  end if;
  select * into v from public.venues
   where id = p_venue and lower(coalesce(listing_owner_email, '')) = em;
  if not found then
    raise exception 'This is not one of your spaces.';
  end if;
  p_rows := coalesce(p_rows, '[]'::jsonb);
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'The prices could not be read.';
  end if;
  if jsonb_array_length(p_rows) > 40 then
    raise exception 'Up to 40 prices, please.';
  end if;
  note_ := 'From the Owner account (' || em || ')';

  -- New prices the owner sent before and has not seen on the page yet
  -- are sent again below, as they are now.
  delete from public.product_changes
   where venue_id = v.id and source = 'owner' and action = 'add'
     and status in ('proposed', 'failed');

  for r in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(r) <> 'object' then
      continue;
    end if;
    if cur is not null then
      r := r || jsonb_build_object('currency', cur);
    end if;

    if coalesce(r->>'id', '') ~ '^[0-9a-fA-F-]{36}$' then
      select * into pr from public.venue_products
       where id = (r->>'id')::uuid and venue_id = v.id and status = 'live';
      if not found then
        continue;
      end if;
      keep := keep || pr.id;
      base := public.product_json(pr);
      fin := public.product_clean(r - 'id', base);
      why := public.product_problem(fin);
      if why is null and lower(fin->>'name') = any(seen) then
        why := 'this name is in your list twice';
      end if;
      if why is not null then
        problems := problems || jsonb_build_array(jsonb_build_object(
          'name', coalesce(r->>'name', pr.name), 'why', why));
        continue;
      end if;
      seen := seen || lower(fin->>'name');
      select * into open_ from public.product_changes x
       where x.product_id = pr.id
         and x.status in ('proposed', 'approved', 'failed', 'undo_requested')
       limit 1;
      has_open := found;
      if fin = public.product_clean('{}'::jsonb, base) then
        -- As on the page: an earlier owner change for it is dropped.
        if has_open and open_.source = 'owner'
           and open_.status in ('proposed', 'failed') then
          delete from public.product_changes where id = open_.id;
        end if;
        continue;
      end if;
      if has_open and open_.status in ('approved', 'undo_requested') then
        problems := problems || jsonb_build_array(jsonb_build_object(
          'name', pr.name,
          'why', 'a change to this price is already on its way to your page'));
        continue;
      end if;
      if has_open then
        delete from public.product_changes where id = open_.id;
      end if;
      insert into public.product_changes
        (venue_id, product_id, action, before, proposed, final, note, source)
      values (v.id, pr.id, 'update', base, fin, fin, note_, 'owner');
      n_up := n_up + 1;
    else
      fin := public.product_clean(r - 'id', jsonb_build_object('currency', cur));
      why := public.product_problem(fin);
      if why is null and lower(fin->>'name') = any(seen) then
        why := 'this name is in your list twice';
      end if;
      if why is null and exists (select 1 from public.venue_products x
             where x.venue_id = v.id and x.status = 'live'
               and lower(x.name) = lower(fin->>'name')
               and not (x.id = any(keep))) then
        why := 'a price with this name is already on your page';
      end if;
      if why is not null then
        problems := problems || jsonb_build_array(jsonb_build_object(
          'name', coalesce(r->>'name', ''), 'why', why));
        continue;
      end if;
      seen := seen || lower(fin->>'name');
      insert into public.product_changes
        (venue_id, action, proposed, final, note, source)
      values (v.id, 'add', fin, fin, note_, 'owner');
      n_add := n_add + 1;
    end if;
  end loop;

  -- Prices on the page that the owner took out of the list.
  for pr in select * from public.venue_products x
             where x.venue_id = v.id and x.status = 'live'
               and not (x.id = any(keep)) loop
    select * into open_ from public.product_changes x
     where x.product_id = pr.id
       and x.status in ('proposed', 'approved', 'failed', 'undo_requested')
     limit 1;
    has_open := found;
    if has_open and open_.status in ('approved', 'undo_requested') then
      continue;
    end if;
    if has_open and open_.action = 'remove' and open_.source = 'owner' then
      continue;   -- already asked for
    end if;
    if has_open then
      delete from public.product_changes where id = open_.id;
    end if;
    insert into public.product_changes
      (venue_id, product_id, action, before, note, source)
    values (v.id, pr.id, 'remove', public.product_json(pr), note_, 'owner');
    n_rm := n_rm + 1;
  end loop;

  return jsonb_build_object('added', n_add, 'changed', n_up, 'removed', n_rm,
                            'problems', problems);
end $$;
revoke all on function public.owner_propose_products(uuid, jsonb, text) from public, anon;
grant execute on function public.owner_propose_products(uuid, jsonb, text) to authenticated;

notify pgrst, 'reload schema';
