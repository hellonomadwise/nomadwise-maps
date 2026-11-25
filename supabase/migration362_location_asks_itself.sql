-- Migration 362: Claude is asked about the Location of every page
-- waiting in Ready to approve, without anyone pressing a button, and
-- the answer shows on the card.
--
-- Jonathan, 25 Nov 2026, on the Ready to approve cards: "I am not
-- initially trusting the use Nimman [suggestion], as in I'm not trusting
-- the location, and so I'm always clicking on nearby spaces on a map and
-- then clicking on Ask Claude, and then tend to be approving those and
-- relying on those ... it's making it take a little bit longer than it
-- should do".
--
-- Why Claude: of the 50 questions where he chose after asking, he took
-- Claude's first option 49 times. The yellow "Suggested Location" box
-- comes from distance to the nearest listed places only.
--
-- What changes:
--   * location_ask_auto() runs every two minutes. It first collects the
--     answers that have come back, then asks Claude about up to eight
--     spaces in Ready to approve (queued, prepared, a Region known, no
--     Location chosen by the founder) that have never been asked, or
--     whose last question failed more than a day ago.
--   * It uses the same question as the Ask Claude button (migration
--     169): the same facts, the founder's earlier choices and reasons.
--     An automatic question has no asked_by.
--   * The three admin functions it calls may run for this job only
--     (a setting only this function sets, for the length of its own
--     transaction). Everyone else still needs to be a founder.
--   * Daily limit on questions raised from 50 to 150, so the 76 pages
--     waiting today are covered in a day and buttons still work. At
--     about one cent a question, 150 is at most about 1.50 dollars a day.
--   * admin_location_asks_latest() gives the app the newest answer for
--     each space in Ready to approve, and which are still waiting.
--   * Off switch: sync_settings 'location_ask_auto' {"on": false}.

select public.pm_patch_fn('public.admin_location_help(uuid,text,text[])',
  $a$if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';$a$,
  $a$if not (coalesce(public.is_admin(), false)
          or current_setting('nomadwise.auto_ask', true) = '1') then
    raise exception 'founders only';$a$,
  $a$nomadwise.auto_ask$a$);

select public.pm_patch_fn('public.admin_location_ask(uuid,text,text[])',
  $a$if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';$a$,
  $a$if not (coalesce(public.is_admin(), false)
          or current_setting('nomadwise.auto_ask', true) = '1') then
    raise exception 'founders only';$a$,
  $a$nomadwise.auto_ask$a$);

select public.pm_patch_fn('public.admin_location_ask(uuid,text,text[])',
  $a$) >= 50 then$a$,
  $a$) >= 150 then$a$,
  $a$>= 150 then$a$);

select public.pm_patch_fn('public.admin_location_ask(uuid,text,text[])',
  $a$'Fifty questions today already.$a$,
  $a$'150 questions today already.$a$,
  $a$150 questions today$a$);

select public.pm_patch_fn('public.admin_location_answer(bigint)',
  $a$if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';$a$,
  $a$if not (coalesce(public.is_admin(), false)
          or current_setting('nomadwise.auto_ask', true) = '1') then
    raise exception 'founders only';$a$,
  $a$nomadwise.auto_ask$a$);

insert into public.sync_settings (key, value)
values ('location_ask_auto', '{"on": true}'::jsonb)
on conflict (key) do nothing;

create or replace function public.location_ask_auto(p_max int default 8)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a      record;
  v      record;
  got    int := 0;
  asked  int := 0;
  failed int := 0;
  r      jsonb;
begin
  if coalesce((select (s.value ->> 'on')::boolean from public.sync_settings s
                where s.key = 'location_ask_auto'), true) is false then
    return jsonb_build_object('off', true);
  end if;
  -- Lets the three admin functions run for this job, in this
  -- transaction only.
  perform set_config('nomadwise.auto_ask', '1', true);

  -- 1. Answers that have come back (or never will).
  for a in
    select q.id from public.location_asks q
     where q.done_at is null and q.request_id is not null
       and q.asked_at < now() - interval '15 seconds'
     order by q.id
     limit 60
  loop
    begin
      r := public.admin_location_answer(a.id);
      if r ->> 'status' <> 'waiting' then got := got + 1; end if;
    exception when others then
      null;
    end;
  end loop;

  -- 2. New questions, top of Ready to approve first.
  for v in
    select x.id from public.venues x
     where x.website_status = 'queued'
       and x.website_prepared is not null
       and nullif(x.website_prepared ->> 'region_id', '') is not null
       and coalesce((x.website_prepared ->> 'location_chosen')::boolean, false) = false
       and not exists (
             select 1 from public.location_asks q
              where q.venue_id = x.id
                and (q.error is null or q.asked_at > now() - interval '1 day'))
     order by x.created_at
     limit greatest(coalesce(p_max, 8), 0)
  loop
    begin
      perform public.admin_location_ask(v.id, null, null);
      asked := asked + 1;
    exception when others then
      failed := failed + 1;
      exit when sqlerrm like '%questions today%' or sqlerrm like '%Claude key%';
    end;
  end loop;

  return jsonb_build_object('answers', got, 'asked', asked, 'failed', failed);
end $$;
revoke all on function public.location_ask_auto(int) from public, anon, authenticated;

-- The newest answer for each space in Ready to approve, and the spaces
-- whose question is still out.
create or replace function public.admin_location_asks_latest()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  return jsonb_build_object(
    'answers', coalesce((
      select jsonb_object_agg(t.venue_id, t.j) from (
        select distinct on (q.venue_id) q.venue_id::text as venue_id,
               jsonb_strip_nulls(jsonb_build_object(
                 'ask', q.id,
                 'region_id', q.region_id,
                 'options', coalesce(q.answer -> 'options', '[]'::jsonb),
                 'note', q.answer ->> 'note',
                 'auto', q.asked_by is null,
                 'chosen', q.chosen,
                 'at', q.done_at)) as j
          from public.location_asks q
          join public.venues x on x.id = q.venue_id
         where x.website_status = 'queued'
           and q.done_at is not null and q.error is null and q.answer is not null
         order by q.venue_id, q.done_at desc) t), '{}'::jsonb),
    'waiting', coalesce((
      select jsonb_agg(distinct q.venue_id::text)
        from public.location_asks q
        join public.venues x on x.id = q.venue_id
       where x.website_status = 'queued' and q.done_at is null), '[]'::jsonb));
end $$;
revoke all on function public.admin_location_asks_latest() from public, anon;
grant execute on function public.admin_location_asks_latest() to authenticated;

select cron.unschedule('location-ask-auto')
 where exists (select 1 from cron.job where jobname = 'location-ask-auto');
select cron.schedule('location-ask-auto', '*/2 * * * *',
                     $c$select public.location_ask_auto(8)$c$);
