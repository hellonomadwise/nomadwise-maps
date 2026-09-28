-- ============================================================
-- Migration 86: "this was me" on a claim journey.
-- (Applied automatically by the build; nothing to paste.)
--
-- A founder testing the claim page shows up in Claim journeys and
-- the funnel like a real owner. Marking a visit as ours adds that
-- browser to team_devices, which every analytics view already
-- leaves out, so its past and future visits disappear from the
-- numbers. Undo removes it again.
-- ============================================================

create or replace function public.mark_team_device(p_anon text, p_team boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  if coalesce(p_anon, '') = '' then return; end if;
  if p_team then
    insert into public.team_devices (anon_id) values (p_anon)
    on conflict (anon_id) do nothing;
  else
    delete from public.team_devices where anon_id = p_anon;
  end if;
end $$;
grant execute on function public.mark_team_device(text, boolean) to authenticated;
