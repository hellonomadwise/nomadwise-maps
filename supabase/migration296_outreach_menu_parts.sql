-- ============================================================
-- Migration 296: the number beside Outreach, made honest and explained
-- ============================================================
-- Jonathan, 9 Nov 2026: "the same with the 12 for outreach. i need to
-- be able to easily see".
--
-- The 12 were all old email threads brought in on 4 Oct 2026 with the
-- stage "replied", where we had in fact written last (some a year
-- ago), three of them set aside as not a fit. The Outreach screen
-- already skips those in its list of replies to answer; the menu
-- number did not. Now the number counts a reply only when they wrote
-- last and the line is not set aside, the same rule as the screen.
--
-- admin_outreach_menu_parts() gives the parts of the number, counted
-- as admin_next_up counts them; the app names them in the tooltip and
-- shows the rest (looked at claiming / made an account) as the
-- difference, so the parts always add up to the number.
-- ============================================================

select public.pm_patch_fn('public.admin_next_up()',
$a$and (c.stage = 'replied'
          or (c.follow_up_on$a$,
$a$and ((c.stage = 'replied'
               -- they wrote last, and the line is not set aside (migration 296)
               and not public.outreach_aside(c.topic, c.stage)
               and (c.last_out_at is null or c.last_in_at > c.last_out_at))
          or (c.follow_up_on$a$,
$m$migration 296$m$);

create or replace function public.admin_outreach_menu_parts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return jsonb_build_object(
    'replied', (select count(*) from public.space_contacts c
                 where not c.is_test and c.stage = 'replied'
                   and not public.outreach_aside(c.topic, c.stage)
                   and (c.last_out_at is null or c.last_in_at > c.last_out_at)),
    'follow_up', (select count(*) from public.space_contacts c
                   where not c.is_test
                     and not (c.stage = 'replied'
                              and not public.outreach_aside(c.topic, c.stage)
                              and (c.last_out_at is null or c.last_in_at > c.last_out_at))
                     and c.follow_up_on is not null and c.follow_up_on <= current_date
                     and (c.last_out_at is null or c.last_out_at::date < c.follow_up_on)
                     and c.stage not in ('claimed', 'verified', 'declined',
                                         'unsubscribed', 'bounced')));
end $$;

revoke all on function public.admin_outreach_menu_parts() from public, anon;
grant execute on function public.admin_outreach_menu_parts() to authenticated;
