-- 173: live pages with no Location, worked through one by one.
--
-- Jonathan, 8 Oct 2026: "i also want a place that makes most sense in
-- the control panel where I can see a list of all spaces in webflow
-- that don't have locations assigned to them, where I can work through
-- them, either assigning that its totally fine that there isn't a
-- location set, that its deliberate, or move through to creating and
-- then assigning a location, and then it getting all linked up with
-- the region and everything within webflow".
--
-- Control centre > Clean-up > No Location. For each live page without
-- a Location:
--   * "No Location is fine": kept as a deliberate choice
--     (website_location_override 'none', as for a space in review) and
--     it leaves the list; "Undo" brings it back.
--   * an existing Location of its Region: website_location_apply holds
--     it until the website sync sets it on the Webflow item and
--     publishes the item again (within minutes), then it is cleared.
--   * a new Location: created the usual way (a taxonomy request, made
--     and wired to its Region by the sync), and website_new_location
--     holds its name; the sync links the page once the Location exists.
-- Every change to a live page starts from a founder's own press in the
-- app, which first says exactly what will change.
-- Safe to apply twice.

alter table public.venues
  add column if not exists website_location_apply text,
  add column if not exists website_location_applied_at timestamptz,
  add column if not exists website_location_error text;

-- ------------------------------------------------ the list
create or replace function public.admin_live_without_location()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  todo    jsonb;
  settled jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;

  with live as (
    select v.id, v.name, v.type, v.city, v.country, v.neighbourhood, v.g_area,
           v.webflow_slug, v.webflow_region_id, v.website_location_override,
           v.website_location_apply, v.website_new_location,
           v.website_location_error, v.website_location_applied_at
      from public.venues v
     where v.webflow_cms_id is not null
       and v.website_status in ('released', 'published_hidden')
       and v.webflow_location_id is null
       and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
  ),
  named as (
    select l.*,
           array(select n from unnest(
                   array[l.neighbourhood]::text[]
                   || coalesce((select array_agg(e ->> 'n' order by o)
                                  from jsonb_array_elements(
                                         case when jsonb_typeof(l.g_area) = 'array'
                                              then l.g_area else '[]'::jsonb end)
                                       with ordinality as a(e, o)), '{}'::text[])
                   || array[l.city]::text[]) with ordinality as t(n, o)
                  where btrim(coalesce(n, '')) <> '' order by o) as names
      from live l
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'id', n.id, 'name', n.name, 'type', n.type,
           'city', n.city, 'country', n.country, 'slug', n.webflow_slug,
           'region_id', n.webflow_region_id, 'region', g.name,
           'region_country', g.country, 'region_kind', coalesce(g.kind, 'city'),
           'locations_in_region', (select count(*) from public.webflow_locations wl
                                    where wl.region_id = n.webflow_region_id
                                      and wl.updated_at > now() - interval '3 days'),
           'applying', case when n.website_location_apply is not null then
                         jsonb_build_object('id', n.website_location_apply,
                           'name', (select wl.name from public.webflow_locations wl
                                     where wl.id = n.website_location_apply)) end,
           'waiting_for', nullif(btrim(coalesce(n.website_new_location, '')), ''),
           'error', n.website_location_error,
           'verdict', case when n.webflow_region_id is not null
                           then public.location_verdict(n.id, n.webflow_region_id, n.names) end))
           order by g.name nulls last, n.name), '[]'::jsonb)
    into todo
    from named n
    left join public.webflow_regions g on g.id = n.webflow_region_id
   where coalesce(n.website_location_override, '') <> 'none';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'name', v.name, 'slug', v.webflow_slug, 'region', g.name)
           order by g.name nulls last, v.name), '[]'::jsonb)
    into settled
    from public.venues v
    left join public.webflow_regions g on g.id = v.webflow_region_id
   where v.webflow_cms_id is not null
     and v.website_status in ('released', 'published_hidden')
     and v.webflow_location_id is null
     and v.website_location_override = 'none';

  return jsonb_build_object('todo', todo, 'settled', settled);
end $$;
revoke all on function public.admin_live_without_location() from public, anon;
grant execute on function public.admin_live_without_location() to authenticated;

-- ------------------------------------------------ a decision on one page
-- p_kind: 'location' (an existing Location of the page's Region, by
-- id), 'new' (a new Location, by name, asked for the usual way first),
-- 'none' (no Location, on purpose), 'undo' (back on the list).
create or replace function public.admin_live_location_set(
  p_venue uuid, p_kind text, p_location text default null, p_name text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v record;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select id, webflow_cms_id, webflow_region_id into v
    from public.venues where id = p_venue;
  if v.id is null or v.webflow_cms_id is null then
    raise exception 'That space has no page on nomadwise.io.';
  end if;

  if p_kind = 'location' then
    if not exists (select 1 from public.webflow_locations l
                    where l.id = p_location
                      and (v.webflow_region_id is null or l.region_id = v.webflow_region_id)) then
      raise exception 'That Location is not in this page''s Region.';
    end if;
    update public.venues
       set website_location_apply = p_location,
           website_new_location = null,
           website_location_error = null
     where id = p_venue;
  elsif p_kind = 'new' then
    if nullif(btrim(coalesce(p_name, '')), '') is null then
      raise exception 'A name is needed.';
    end if;
    update public.venues
       set website_new_location = left(btrim(p_name), 80),
           website_location_apply = null,
           website_location_error = null
     where id = p_venue;
  elsif p_kind = 'none' then
    update public.venues
       set website_location_override = 'none',
           website_location_apply = null,
           website_new_location = null,
           website_location_error = null
     where id = p_venue;
  elsif p_kind = 'undo' then
    update public.venues
       set website_location_override = case when website_location_override = 'none'
                                            then null else website_location_override end,
           website_location_apply = null,
           website_new_location = null,
           website_location_error = null
     where id = p_venue;
  else
    raise exception 'Unknown choice.';
  end if;
end $$;
revoke all on function public.admin_live_location_set(uuid, text, text, text) from public, anon;
grant execute on function public.admin_live_location_set(uuid, text, text, text) to authenticated;
