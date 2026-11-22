-- Enquiries tab: which spaces have used free enquiries, and how many
-- (Jonathan, 22 Nov 2026, after Madeira Friends Hub had its first free
-- one: "does that mean then that madeira friends has now used 1 or its
-- 2 requests?" and "how can I easily see this within nomadmaps?").
--
-- Until now the count was only in the phone notification ("Free enquiry
-- 1 of 2 sent to ..."), in the owner's own account, and, once all were
-- used, under "Held for Premium". admin_enquiries_held() now also
-- returns 'free_used': one line per space that is not on Premium and
-- has used at least one, the fullest first, then the most recent.
-- Nothing else about the function changes.
create or replace function public.admin_enquiries_held()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
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
       where e.status = 'held'), '[]'::jsonb),
    'free_used', coalesce((
      select jsonb_agg(jsonb_build_object(
               'venue_id', s.venue_id, 'venue_name', s.venue_name,
               'city', s.city, 'used', s.used, 'held', s.held,
               'last_at', s.last_at, 'last_name', s.last_name)
             order by s.used desc, s.last_at desc)
        from (
          select v.id as venue_id, v.name as venue_name, v.city,
                 count(*) filter (where e.free_slot)::int as used,
                 count(*) filter (where e.status = 'held')::int as held,
                 max(e.created_at) filter (where e.free_slot) as last_at,
                 (array_agg(e.name order by e.created_at desc)
                    filter (where e.free_slot))[1] as last_name
            from public.enquiries e
            join public.venues v on v.id = e.venue_id
           where coalesce(v.listing_tier, 'free') <> 'verified'
           group by v.id, v.name, v.city
          having count(*) filter (where e.free_slot) > 0
        ) s), '[]'::jsonb));
end $function$;
