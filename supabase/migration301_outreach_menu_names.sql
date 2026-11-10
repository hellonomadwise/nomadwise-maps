-- ============================================================
-- Migration 301: the number beside Outreach names its spaces
-- ============================================================
-- Jonathan, 10 Nov 2026: "the 1 on the left. when i click into
-- outreach, I can't work out what the 1 is. i want to be able to know
-- how to action that 1". It was Avila Spaces, whose follow-up date had
-- come. admin_outreach_menu_parts() now also gives the names behind
-- the replies and follow-ups (up to five each), so the menu's tooltip
-- and the top of Outreach's To do can say who.
-- ============================================================

create or replace function public.admin_outreach_menu_parts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  replied jsonb;
  due     jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;

  select jsonb_build_object(
           'n', count(*),
           'names', coalesce(jsonb_agg(x.space_name order by x.last_in_at desc nulls last)
                               filter (where x.rn <= 5), '[]'::jsonb))
    into replied
    from (select c.space_name, c.last_in_at,
                 row_number() over (order by c.last_in_at desc nulls last) rn
            from public.space_contacts c
           where not c.is_test and c.stage = 'replied'
             and not public.outreach_aside(c.topic, c.stage)
             and (c.last_out_at is null or c.last_in_at > c.last_out_at)) x;

  select jsonb_build_object(
           'n', count(*),
           'names', coalesce(jsonb_agg(x.space_name order by x.follow_up_on)
                               filter (where x.rn <= 5), '[]'::jsonb))
    into due
    from (select c.space_name, c.follow_up_on,
                 row_number() over (order by c.follow_up_on) rn
            from public.space_contacts c
           where not c.is_test
             and not (c.stage = 'replied'
                      and not public.outreach_aside(c.topic, c.stage)
                      and (c.last_out_at is null or c.last_in_at > c.last_out_at))
             and c.follow_up_on is not null and c.follow_up_on <= current_date
             and (c.last_out_at is null or c.last_out_at::date < c.follow_up_on)
             and c.stage not in ('claimed', 'verified', 'declined',
                                 'unsubscribed', 'bounced')) x;

  return jsonb_build_object(
    'replied', (replied ->> 'n')::int,
    'replied_names', replied -> 'names',
    'follow_up', (due ->> 'n')::int,
    'follow_up_names', due -> 'names');
end $$;

revoke all on function public.admin_outreach_menu_parts() from public, anon;
grant execute on function public.admin_outreach_menu_parts() to authenticated;
