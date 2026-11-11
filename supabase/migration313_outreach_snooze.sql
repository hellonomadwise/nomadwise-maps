-- ============================================================
-- Migration 313: snooze a line in Outreach ("give them time")
-- ============================================================
-- Jonathan, 11 Nov 2026, on Madeira Friends Hub under "They showed
-- interest" (they opened their claim page 15 hours ago, a day after we
-- wrote to them): "I would like the option of snoozing this listing
-- ... I don't want to repeatedly send them a message. So I want the
-- opportunity to delay the suggestion, to wait if they try and claim
-- again on their own."
--
-- "Done for now" was the nearest thing, and it brings the space back
-- the moment its claim page is opened again: the opposite of leaving
-- them to it. A snooze leaves the space alone until a date:
--   * it is off To do until then, whatever they open in the meantime;
--   * if they claim, it never comes back (a claim ends the look);
--   * if not, it is back on To do on that day.
-- One date for the whole space (all its lines), kept in
-- space_contacts.snooze_until. A follow-up date that has already come
-- moves to the same day, so the line does not return early as a
-- follow-up.
-- ============================================================

alter table public.space_contacts add column if not exists snooze_until timestamptz;

-- p_days > 0: leave it for that many days. p_days <= 0: end the snooze.
create or replace function public.admin_outreach_snooze(p_id uuid, p_days integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  vid   uuid;
  till  timestamptz;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select c.venue_id into vid from public.space_contacts c where c.id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
  if coalesce(p_days, 0) > 0 then
    till := now() + make_interval(days => least(p_days, 180));
  end if;
  update public.space_contacts c
     set snooze_until = till,
         follow_up_on = case when till is not null and c.follow_up_on is not null
                                  and c.follow_up_on <= current_date
                             then till::date else c.follow_up_on end,
         updated_at = now()
   where c.id = p_id or (vid is not null and c.venue_id = vid);
  return jsonb_build_object('until', till);
end $$;

revoke all on function public.admin_outreach_snooze(uuid, integer) from public, anon;
grant execute on function public.admin_outreach_snooze(uuid, integer) to authenticated;

-- a claim page that was opened: not while the space is snoozed
select public.pm_patch_fn('public.claim_look_lines()',
$a$or s.claim_look_done_at >= l.last_at));$a$,
$a$or s.claim_look_done_at >= l.last_at
                             -- or left alone until a day that has not come (migration 313)
                             or s.snooze_until > now()));$a$,
$m$left alone until a day that has not come (migration 313)$m$);

-- an account made on the map: the same
select public.pm_patch_fn('public.signup_lines()',
$a$or s.signup_done_at >= m.signed_up_at))$a$,
$a$or s.signup_done_at >= m.signed_up_at
                             -- or left alone until a day that has not come (migration 313)
                             or s.snooze_until > now()))$a$,
$m$left alone until a day that has not come (migration 313)$m$);

-- the lists carry the date, so Waiting can say "snoozed until"
select public.pm_patch_fn('public.admin_outreach_list(text,text,integer,text,text)',
$a$c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,$a$,
$a$c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.snooze_until,   -- (migration 313)$a$,
$m$c.snooze_until,   -- (migration 313)$m$);

notify pgrst, 'reload schema';
