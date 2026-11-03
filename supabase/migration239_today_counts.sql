-- ============================================================
-- Migration 239: what the new Today screen needs from admin_next_up.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 3 Nov 2026: Nomad Maps' admin opens on "Today", one job at
-- a time, step by step. Two more parts in admin_next_up:
--   'follow_up'  Outreach follow-ups that have come due (the date set
--                on a box has arrived and nothing went since): how
--                many, and the one due longest.
--   'waiting'    for the "Waiting on others" card: spaces we wrote to
--                that have not answered ('n'), and boxes with a
--                follow-up date still to come ('later').
-- Patched where it stands (after migration 234's 'replied_wait').
-- Pure ASCII. Safe to apply twice.
-- ============================================================

do $do$
declare
  src    text;
  marker text := '  -- The numbers beside the menu''s other tools (migration 146)';
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'admin_next_up';
  if src is null or position('''follow_up''' in src) > 0 then
    return;  -- not there, or done already
  end if;
  if position(marker in src) = 0 then
    raise exception 'admin_next_up is not as expected; Today counts not added';
  end if;
  src := replace(src, marker,
$add$  -- Outreach follow-ups that have come due (migration 239): how many,
  -- and the one due longest.
  begin
    select jsonb_build_object(
             'n', count(*),
             'name', (array_agg(c.space_name order by c.follow_up_on, c.last_out_at nulls first))[1])
      into part
      from public.space_contacts c
     where not c.is_test
       and not public.outreach_aside(c.topic, c.stage)
       and public.outreach_follow_up_due(c.stage, c.follow_up_on, c.last_out_at);
    out := out || jsonb_build_object('follow_up', part);
  exception when others then
    null;
  end;

  -- Waiting on others (migration 239): spaces we wrote to that have
  -- not answered, and follow-up dates still to come.
  begin
    select jsonb_build_object(
             'n', count(*) filter (where c.stage = 'contacted'),
             'later', count(*) filter (where c.follow_up_on > current_date
                                         and c.stage not in ('claimed', 'verified', 'declined',
                                                             'unsubscribed', 'bounced')))
      into part
      from public.space_contacts c
     where not c.is_test
       and not public.outreach_aside(c.topic, c.stage);
    out := out || jsonb_build_object('waiting', part);
  exception when others then
    null;
  end;

$add$ || marker);
  execute src;
end
$do$;
