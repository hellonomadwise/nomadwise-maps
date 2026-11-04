-- Migration 250: "Temporarily closed" from the Owner account (CR-36).
--
-- An owner marks their space temporarily closed (building work,
-- holidays) by picking the day it opens again. It goes on the page at
-- once, without review: a wrong "closed" only affects them. The page
-- (nomadwise.io, via prices.js and page_prices) shows "Temporarily
-- closed. <Space> opens again on <day>." until that day, then goes back
-- to normal by itself. Clearing the date ("Open again now") takes it off.
--
-- Google stays the baseline for everyone: business_status from the
-- nightly run is not shown on the page by this.

alter table public.venues
  add column if not exists owner_reopens_on date,
  add column if not exists owner_closed_set_at timestamptz,
  add column if not exists owner_closed_set_by text;

comment on column public.venues.owner_reopens_on is
  'Owner said the space is temporarily closed until this day (it opens again on it). Shown on the page while today is before it. Migration 250.';

-- The owner (or the team, from Team edit) sets or clears the day.
create or replace function public.owner_set_closed(p_venue uuid, p_reopens date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  em    text := public.owner_email();
  admin boolean := coalesce(public.is_admin(), false);
  v     public.venues%rowtype;
begin
  if em is null and not admin then
    raise exception 'Please sign in again.';
  end if;
  select * into v from public.venues
   where id = p_venue
     and (admin or lower(coalesce(listing_owner_email, '')) = em)
   for update;
  if not found then
    raise exception 'This is not one of your spaces.';
  end if;
  if p_reopens is not null then
    if p_reopens <= current_date then
      raise exception 'Please pick a day after today.';
    end if;
    if p_reopens > current_date + 366 then
      raise exception 'Please pick a day within the next year.';
    end if;
  end if;

  update public.venues
     set owner_reopens_on = p_reopens,
         owner_closed_set_at = now(),
         owner_closed_set_by = coalesce(em, 'team')
   where id = v.id;

  return jsonb_build_object('reopens_on', p_reopens);
end $function$;

revoke all on function public.owner_set_closed(uuid, date) from public, anon;
grant execute on function public.owner_set_closed(uuid, date) to authenticated;

-- The Owner account (and the founders' preview) read it with the rest
-- of the listing.
create or replace function public.owner_page_extras(v venues)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
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
          and c.status in ('proposed', 'approved', 'failed')),
    -- Temporarily closed until this day (migration 250); null once it
    -- has passed.
    'reopens_on', case when v.owner_reopens_on > current_date
                       then v.owner_reopens_on end)
$function$;

-- The listing page asks once per visit (prices.js): the price list, if
-- this page has it switched on, and the closed notice on every page.
create or replace function public.page_prices(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  cfg    jsonb;
  slug_  text := lower(btrim(coalesce(p_slug, '')));
  v      record;
  items  jsonb;
  closed jsonb;
begin
  if slug_ = '' or length(slug_) > 200 then
    return jsonb_build_object('show', false);
  end if;

  select x.id, x.name, x.owner_reopens_on into v
    from public.venues x
   where x.webflow_slug = slug_
   limit 1;
  if v.id is null then
    select x.id, x.name, x.owner_reopens_on into v
      from public.venues x
     where lower(x.webflow_slug) = slug_
     limit 1;
  end if;
  if v.id is null then
    return jsonb_build_object('show', false);
  end if;
  if v.owner_reopens_on > current_date then
    closed := jsonb_build_object('space', v.name, 'reopens_on', v.owner_reopens_on);
  end if;

  select value into cfg from public.sync_settings where key = 'price_cards';
  if not coalesce((cfg ->> 'on')::boolean, false)
     and not coalesce(cfg -> 'slugs', '[]'::jsonb) ? slug_ then
    return jsonb_build_object('show', false, 'closed', closed);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'name', p.name,
           'category', coalesce(nullif(p.category, ''), 'coworking'),
           'amount', p.amount,
           'currency', p.currency,
           'label', p.price_label,
           'from', coalesce(p.starting_from, false),
           'vat_included', p.vat_included,
           'details', coalesce(p.details, '[]'::jsonb))
           order by p.position, p.created_at), '[]'::jsonb)
    into items
    from public.venue_products p
   where p.venue_id = v.id and p.status = 'live';

  return jsonb_build_object(
    'show', jsonb_array_length(items) > 0,
    'space', v.name,
    'prices', items,
    'closed', closed);
end $function$;
