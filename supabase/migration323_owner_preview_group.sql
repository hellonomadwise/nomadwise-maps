-- ============================================================
-- Migration 323: the Owner account preview shows the whole account
-- ============================================================
-- Jonathan, 12 Nov 2026, on SwissOffices (three Istanbul spaces on one
-- owner's address): "whats the best way to see the owner area as they
-- see it when they login, i want to see how the join account works,
-- where they can see the multiple spaces".
--
-- "Their Owner account" opened one space only (admin_owner_view), so
-- a founder never saw All locations or the name menu with the other
-- spaces, which is where an owner with two or more spaces lands.
--
-- * admin_owner_view_group(key): every space on the same owner's
--   address as the one asked for, each exactly as admin_owner_view
--   gives it, in the owner's order (by name). One space, or none with
--   an owner: just that space.
-- * admin_owner_locations(key): the last 30 days of each (page views,
--   times shown in Google, requests), the numbers owner_locations()
--   gives the owner on All locations.
-- Founders only, read only; nothing is counted as a visit by the owner.
-- ============================================================

create or replace function public.admin_owner_view_group(p_key text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  vid uuid;
  em  text;
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  select v.id, lower(nullif(btrim(coalesce(v.listing_owner_email, '')), ''))
    into vid, em
    from public.venues v
   where v.id::text = p_key or v.webflow_slug = p_key
   limit 1;
  if vid is null then
    return '[]'::jsonb;
  end if;
  if em is null then
    return jsonb_build_array(public.admin_owner_view(vid::text));
  end if;
  select coalesce(jsonb_agg(public.admin_owner_view(v.id::text) order by v.name), '[]'::jsonb)
    into out
    from public.venues v
   where lower(v.listing_owner_email) = em;
  return out;
end $function$;

revoke all on function public.admin_owner_view_group(text) from public, anon;
grant execute on function public.admin_owner_view_group(text) to authenticated;

create or replace function public.admin_owner_locations(p_key text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  em    text;
  today date := (now() at time zone 'utc')::date;
  g_end date;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  select lower(nullif(btrim(coalesce(v.listing_owner_email, '')), ''))
    into em
    from public.venues v
   where v.id::text = p_key or v.webflow_slug = p_key
   limit 1;
  if em is null then
    return '[]'::jsonb;
  end if;
  select max(day) into g_end from public.page_google_days;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', v.id,
             'views', coalesce((select sum(c.n) from public.page_counts c
                                 where c.venue_id = v.id and c.kind = 'view'
                                   and c.day > today - 30), 0),
             'google', coalesce((select sum(g.impressions) from public.page_google_days g
                                  where g.venue_id = v.id and g_end is not null
                                    and g.day > g_end - 30 and g.day <= g_end), 0),
             'requests', (select count(*) from public.enquiries e
                           where e.venue_id = v.id and e.status <> 'closed'
                             and e.created_at > now() - interval '30 days'))
             order by v.name)
      from public.venues v
     where lower(coalesce(v.listing_owner_email, '')) = em), '[]'::jsonb);
end $function$;

revoke all on function public.admin_owner_locations(text) from public, anon;
grant execute on function public.admin_owner_locations(text) to authenticated;
