-- ============================================================
-- Migration 295: "Not a person" on a claim look in Outreach
-- ============================================================
-- Jonathan, 9 Nov 2026, on Fora - Green Park House ("Someone opened
-- the claim page 9 days ago ... from United States ... on a phone"):
-- "I want to have an option where I can ignore this particular one
-- because I don't believe that it was a human that did that ... it just
-- ignores it and removes it off of our to-dos".
--
-- admin_outreach_look_not_person(p_id): every visitor that opened this
-- space's claim page in the last 60 days (not one of our devices) is
-- marked as not a person, as "Not a person" in Claim journeys does
-- (bot_visitors, migration 181), so those visits leave the numbers and
-- that visitor never counts again; and the look is settled
-- (claim_look_done_at, as Done for now). A visit from anyone else later
-- shows again. Returns how many visitors were marked.
-- ============================================================

create or replace function public.admin_outreach_look_not_person(p_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.venues%rowtype;
  n integer := 0;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select x.* into v from public.venues x
    join public.space_contacts c on c.venue_id = x.id
   where c.id = p_id;
  if found then
    with lookers as (
      select distinct e.anon_id
        from public.app_events e
       where left(e.name, 6) = 'claim_'
         and e.created_at > now() - interval '60 days'
         and coalesce(e.anon_id, '') <> ''
         and not exists (select 1 from public.team_devices t where t.anon_id = e.anon_id)
         and ((coalesce(v.webflow_slug, '') <> '' and e.props ->> 'seed' = v.webflow_slug)
              or lower(coalesce(nullif(e.props ->> 'space', ''), e.props ->> 'seed', '')) = lower(v.name))
    ), added as (
      insert into public.bot_visitors (anon_id, why, how)
      select l.anon_id, 'Marked in Outreach: not a person (' || v.name || ')', 'hand'
        from lookers l
      on conflict (anon_id) do nothing
      returning 1
    )
    select count(*) into n from added;
  end if;
  perform public.admin_outreach_look_done(p_id);
  return n;
end $$;

revoke all on function public.admin_outreach_look_not_person(uuid) from public, anon;
grant execute on function public.admin_outreach_look_not_person(uuid) to authenticated;
