-- ============================================================
-- Nomadwise Maps — migration 23: who discovered / first screened
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- One small lookup the space page can call to show credit:
--   discovered_by = the nomad whose area search first put the
--                   place on the map (discovery bonus person)
--   screened_by   = the nomad whose first verified "new space"
--                   review screened it
-- Only public display names leave the database.
-- ============================================================

create or replace function public.venue_credits(p_venue_id uuid)
returns json language sql stable security definer set search_path = public as
$$
  select json_build_object(
    'discovered_by', (
      select coalesce(nullif(p.display_name, ''), 'A nomad')
        from public.venues v
        join public.discovered_places d
          on d.google_place_id = v.google_place_id
        join public.profiles p on p.id = d.discovered_by
       where v.id = p_venue_id
       limit 1),
    'screened_by', (
      select coalesce(nullif(p.display_name, ''), 'A nomad')
        from public.submissions s
        join public.profiles p on p.id = s.user_id
       where s.venue_id = p_venue_id
         and s.status = 'verified'
         and s.kind = 'new_venue'
       order by s.created_at asc
       limit 1)
  )
$$;

grant execute on function public.venue_credits(uuid) to anon, authenticated;
