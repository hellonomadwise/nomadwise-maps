-- Migration 334: nothing an owner sends is dropped, and nothing is
-- left waiting on us without a word.
--
-- Jonathan, 17 Nov 2026, after Steve's changes (Neighbors and Nomads)
-- fell out of Owner changes because he went on editing after
-- submitting: "Yes please do that. Is there a way to ensure that things
-- don't get missed or dropped off. We wouldn't want it to affect /
-- delay the owner experience".
--
-- 1. A submitted listing stays submitted. The Owner account saves a
--    draft three seconds after any edit; that save took a submitted
--    listing back to "draft", out of our queue, with nothing said to
--    the owner or to us. Now it stays in the queue with the later
--    edits in it, and the review shows "edited since submitting".
-- 2. A watch on everything that waits on us. Every half hour, each
--    queue is read; anything waiting longer than its limit goes to the
--    phone in ONE notification ("Waiting on us"), and again once a day
--    for as long as it still waits. Nothing is sent at night, and
--    nothing at all when nothing waits.
--
--    What is watched, and for how long before it is said:
--      Owner changes to review            3 hours
--      Owner price list to check          3 hours
--      Claim to approve                   3 hours
--      Owner message not read             3 hours
--      Request to pass on                 3 hours
--      Website chat waiting for us        2 hours
--      Page not updated after a change    1 hour (or an error)
--      Suggestion from a visitor          2 days
--      Reply from a space not answered    2 days

-- ------------------------------------------------ 1. stays submitted
select public.pm_patch_fn('public.owner_save_draft(uuid,jsonb,boolean)',
  $a$           status = case when p_submit then 'submitted' else 'draft' end,$a$,
  $a$           -- (an edit after submitting does not take the listing
           -- out of our queue: migration 334)
           status = case when p_submit or d.status = 'submitted'
                         then 'submitted' else 'draft' end,$a$,
  $a$d.status = 'submitted'$a$);

-- the review is told when the listing was last edited
select public.pm_patch_fn('public.owner_drafts_to_review()',
  $a$      'submitted_at', d.submitted_at,$a$,
  $a$      'submitted_at', d.submitted_at,
      'updated_at', d.updated_at,$a$,
  $a$'updated_at', d.updated_at$a$);

-- ------------------------------------------------ 2. the watch
create table if not exists public.waiting_nudges (
  key         text primary key,
  first_seen  timestamptz not null default now(),
  last_nudged timestamptz
);
alter table public.waiting_nudges enable row level security;
revoke all on table public.waiting_nudges from public, anon, authenticated;

-- Everything that waits on one of us, with since when and how many
-- hours it may wait before the phone is told.
create or replace function public.waiting_on_us()
returns table (kind text, key text, label text, since timestamptz, limit_h integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  select 'Owner changes'::text, 'draft:' || d.id, v.name,
         coalesce(d.submitted_at, d.updated_at), 3
    from public.owner_drafts d
    join public.venues v on v.id = d.venue_id
   where d.status = 'submitted'
  union all
  select 'Owner price list', 'prices:' || pc.venue_id, v.name, min(pc.created_at), 3
    from public.product_changes pc
    join public.venues v on v.id = pc.venue_id
   where pc.status = 'proposed' and pc.source = 'owner'
   group by pc.venue_id, v.name
  union all
  select 'Claim to approve', 'claim:' || c.id, coalesce(nullif(btrim(c.space_name), ''), 'a space'),
         coalesce(c.paid_at, c.created_at), 3
    from public.listing_claims c
   where c.status in ('awaiting_approval', 'free_pending')
  union all
  select 'Owner message', 'chat:' || m.venue_id, v.name, min(m.at), 3
    from public.space_chat_messages m
    join public.venues v on v.id = m.venue_id
   where not m.from_team and m.read_at is null
   group by m.venue_id, v.name
  union all
  select 'Request to pass on', 'enquiry:' || e.id, coalesce(v.name, nullif(btrim(e.listing_text), ''), 'a space'),
         e.created_at, 3
    from public.enquiries e
    left join public.venues v on v.id = e.venue_id
   where e.status = 'waiting'
  union all
  select 'Website chat', 'sitechat:' || c.id,
         coalesce(nullif(btrim(c.visitor_name), ''), 'a visitor'), c.last_at, 2
    from public.site_chats c
   where c.status = 'open'
     and (c.needs_team
          or (c.mode = 'team' and (select m.role from public.site_chat_messages m
                                    where m.chat_id = c.id order by m.id desc limit 1) = 'visitor'))
  union all
  select 'Page not updated', 'sync:' || v.id, v.name, v.listing_sync_requested_at, 1
    from public.venues v
   where v.webflow_cms_id is not null
     and v.listing_sync_requested_at is not null
     and (v.listing_synced_at is null or v.listing_sync_error is not null)
  union all
  select 'Suggestion from a visitor', 'update:' || u.id,
         coalesce(nullif(btrim(u.space_name), ''), 'a space'), u.created_at, 48
    from public.listing_updates u
   where u.status = 'open'
  union all
  select 'Reply not answered', 'reply:' || c.id,
         coalesce(nullif(btrim(c.space_name), ''), 'a space'), c.last_in_at, 48
    from public.space_contacts c
   where c.stage = 'replied' and not coalesce(c.is_test, false)
     and c.last_in_at is not null
     and (c.last_out_at is null or c.last_in_at > c.last_out_at)
     and (c.snooze_until is null or c.snooze_until < now());
$$;
revoke all on function public.waiting_on_us() from public, anon;
grant execute on function public.waiting_on_us() to authenticated, service_role;

-- Run by the clock, every half hour. One notification for everything
-- over its limit that has not been said in the last 20 hours. p_dry:
-- say what would be sent, send nothing, remember nothing.
create or replace function public.waiting_on_us_run(p_dry boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  hour_  integer := extract(hour from now() at time zone 'UTC')::integer;
  lines  text[];
  keys   text[];
  n      integer;
  body   text;
begin
  -- what is no longer waiting is forgotten
  if not p_dry then
    delete from public.waiting_nudges w
     where not exists (select 1 from public.waiting_on_us() x where x.key = w.key);
  end if;

  select array_agg(x.kind || ': ' || x.label || ' (' ||
                   case when x.age_h >= 48 then (x.age_h / 24) || ' days'
                        when x.age_h >= 2 then x.age_h || ' hours'
                        else 'over an hour' end || ')'
                   order by x.since),
         array_agg(x.key order by x.since)
    into lines, keys
    from (select w.*, (extract(epoch from (now() - w.since)) / 3600)::integer as age_h
            from public.waiting_on_us() w) x
    left join public.waiting_nudges g on g.key = x.key
   where x.since < now() - make_interval(hours => x.limit_h)
     and (g.last_nudged is null or g.last_nudged < now() - interval '20 hours');

  n := coalesce(array_length(lines, 1), 0);
  if n = 0 then
    return jsonb_build_object('sent', false, 'waiting', 0);
  end if;
  -- Not at night (Jonathan and Leonie are two hours ahead of this
  -- clock in summer, one in winter): it is said in the morning.
  if not p_dry and (hour_ < 6 or hour_ >= 19) then
    return jsonb_build_object('sent', false, 'waiting', n, 'held', 'night');
  end if;

  body := array_to_string(lines[1:6], E'\n')
          || case when n > 6 then E'\n' || 'and ' || (n - 6) || ' more' else '' end;
  if not p_dry then
    perform public.notify_phone(
      'Waiting on us (' || n || ')', body, 'hourglass_flowing_sand');
    insert into public.waiting_nudges (key, last_nudged)
    select k, now() from unnest(keys) k
    on conflict (key) do update set last_nudged = excluded.last_nudged;
  end if;
  return jsonb_build_object('sent', not p_dry, 'waiting', n, 'text', body);
end $function$;
revoke all on function public.waiting_on_us_run(boolean) from public, anon, authenticated;

-- every half hour
select cron.unschedule(jobid) from cron.job where jobname = 'waiting-on-us';
select cron.schedule('waiting-on-us', '3,33 * * * *', $$select public.waiting_on_us_run()$$);
