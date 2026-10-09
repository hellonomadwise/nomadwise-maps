-- 176: a blocked crawler gets an empty map.
--
-- Jonathan, 9 Oct 2026: stop the Singapore crawler (Tencent Cloud,
-- 43.172.0.0/16 and 43.173.0.0/16, blocked by the bot guard of
-- migration 164) from loading the map. Until now a blocked network was
-- only kept out of the numbers and the phone notices: every visit
-- still downloaded all the spaces, which spends the data allowance
-- (migration 175). map_venues() now answers a visit from a blocked
-- network with an empty list. Everyone else is unchanged.
-- As migration 175 otherwise. Safe to apply twice.

create or replace function public.map_venues()
returns jsonb language plpgsql stable set search_path = public as $$
begin
  if coalesce(public.visit_blocked(), false) then
    return '[]'::jsonb;
  end if;
  -- As the map's own read: a place Google reports closed for good
  -- leaves the map, unless a founder has said it is still open.
  return (select coalesce(jsonb_agg(public.map_venue_row(v)), '[]'::jsonb)
            from public.venues v
           where v.business_status is null
              or v.business_status <> 'CLOSED_PERMANENTLY'
              or v.closed_dismissed_at is not null);
end $$;
grant execute on function public.map_venues() to anon, authenticated;

-- Also 9 Oct 2026: Jonathan's own phone counted as a visitor. Its app
-- id and his account are added to the team's devices, so the in-app
-- numbers leave out its visits. (From now on a founder's device marks
-- itself when the founder signs in: the app, same day.)
insert into public.team_devices (anon_id)
values ('anon-1791397329261-11990904'), ('22617163-b4ff-4a28-a35c-81e48be9db40')
on conflict (anon_id) do nothing;
