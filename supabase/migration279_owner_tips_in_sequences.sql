-- ============================================================
-- Migration 279: owner tips in Sequences (Nomad Maps).
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: "Should this be available in the sequence area
-- in nomad maps?" Yes: the tips now sit in Sequences next to the
-- sign-in reminders, with the same switches.
--  * One switch for all tips, one per tip email, one per space.
--  * The route: the four tips, each with its words and how often sent.
--  * Every owner's space: what is due next, what is waiting (and why),
--    switched off, or unsubscribed.
-- The tips' on/off now lives here (sequences 'owner_tips'), not in
-- sync_settings; it starts as it is now.
-- ============================================================

insert into public.sequences (key, name, enabled)
values ('owner_tips', 'Owner tips',
        coalesce((select (s.value ->> 'on')::boolean from public.sync_settings s where s.key = 'owner_tips'), false))
on conflict (key) do nothing;
insert into public.sequence_steps (sequence_key, step, enabled)
select 'owner_tips', g, true from generate_series(1, 4) g
on conflict do nothing;

create or replace function public.owner_tip_step(p_kind text) returns int
language sql immutable as $$
  select case p_kind when 'tip_next' then 1 when 'tip_complete' then 2 when 'tip_quiet' then 3
                     when 'tip_first_request' then 4 end;
$$;

-- the run follows these switches
select public.pm_patch_fn('public.owner_tips_run(boolean)',
  $a$coalesce((select (s.value ->> 'on')::boolean from public.sync_settings s where s.key = 'owner_tips'), false)$a$,
  $a$coalesce((select q.enabled from public.sequences q where q.key = 'owner_tips'), false)$a$,
  $m$q.key = 'owner_tips'$m$);

select public.pm_patch_fn('public.owner_tips_run(boolean)',
  $a$       or not public.owner_wants_email(d.email, 'tips') then$a$,
  $a$       or exists (select 1 from public.sequence_exclusions x where x.sequence_key = 'owner_tips' and x.venue_id = d.venue_id)
       or not coalesce((select st.enabled from public.sequence_steps st where st.sequence_key = 'owner_tips'
                          and st.step = public.owner_tip_step(d.kind)), false)
       or not public.owner_wants_email(d.email, 'tips') then$a$,
  $m$public.owner_tip_step(d.kind)$m$);

-- What Sequences shows for the tips.
create or replace function public.owner_tips_sequence() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  seq   public.sequences%rowtype;
  due   jsonb;
  spaces jsonb;
  label jsonb := '{"tip_next": "the next thing to add", "tip_complete": "page complete", "tip_quiet": "since you last looked", "tip_first_request": "first request"}';
begin
  select * into seq from public.sequences where key = 'owner_tips';
  select coalesce(jsonb_object_agg(d.venue_id::text, jsonb_build_object('kind', d.kind)), '{}'::jsonb)
    into due from public.owner_tips_due() d;

  with v as (
    select v.id, v.name, v.city, v.country, lower(btrim(v.listing_owner_email)) as em,
           coalesce(nullif(btrim(v.listing_owner_name), ''),
             (select lc.owner_name from public.listing_claims lc where lc.venue_id = v.id order by lc.created_at desc limit 1)) as owner_name,
           (select min(lc.created_at) from public.listing_claims lc where lc.venue_id = v.id) as claimed_at,
           due -> v.id::text ->> 'kind' as kind
      from public.venues v
     where coalesce(btrim(v.listing_owner_email), '') <> ''
       and v.website_status = 'released' and coalesce(v.webflow_slug, '') <> ''
       and lower(btrim(v.listing_owner_email)) not in (select e.email from public.owner_flow_team_emails e)
       and lower(btrim(v.listing_owner_email)) not like '%nomadwise%'
  ), w as (
    select v.*,
      (select max(o.created_at) from public.owner_emails o where lower(o.to_email) = v.em and o.kind like 'tip\_%') as last_tip,
      (select max(o.created_at) from public.owner_emails o where lower(o.to_email) = v.em and o.kind = 'monthly') as last_monthly,
      (select string_agg(replace(o.kind, 'tip_', '') || ' ' || to_char(o.created_at, 'FMDD Mon'), ', ' order by o.created_at)
         from public.owner_emails o where o.venue_id = v.id and o.kind like 'tip\_%') as sent_list,
      exists (select 1 from public.sequence_exclusions x where x.sequence_key = 'owner_tips' and x.venue_id = v.id) as excluded,
      not public.owner_wants_email(v.em, 'tips') as unsubscribed
      from v
  ), s as (
    select w.*,
      greatest(
        case when extract(day from now() at time zone 'utc') <= 10
             then date_trunc('month', now() at time zone 'utc') + interval '10 days' end,
        w.last_tip + interval '7 days',
        w.last_monthly + interval '5 days') as hold_until
      from w
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'venue_id', s.id, 'name', s.name, 'city', s.city, 'country', s.country,
      'owner_name', s.owner_name, 'owner_email', s.em, 'claimed_at', s.claimed_at,
      'status', case when s.excluded then 'off' when s.unsubscribed then 'unsubscribed'
                     when s.kind is null then 'none'
                     when s.hold_until > now() then 'waiting' else 'due' end,
      'next_at', case when s.kind is not null and s.hold_until > now() then s.hold_until end,
      'note', concat_ws(U&' \00B7 ',
        case when s.sent_list is not null then 'Sent: ' || s.sent_list end,
        case when s.excluded then 'Switched off for this space'
             when s.unsubscribed then 'Unsubscribed from tips: nothing is sent'
             when s.kind is null then 'Nothing due now'
             when s.hold_until > now() then 'Next: ' || (label ->> s.kind) || ', from ' || to_char(s.hold_until, 'FMDD Mon')
             else 'Next: ' || (label ->> s.kind) || ', at the next daily run' end))
    order by case when s.excluded or s.unsubscribed then 3 when s.kind is null then 2
                  when s.hold_until > now() then 1 else 0 end, s.name), '[]'::jsonb)
    into spaces from s;

  return jsonb_build_object(
    'key', seq.key, 'name', seq.name, 'enabled', seq.enabled,
    'updated_at', seq.updated_at, 'updated_by', seq.updated_by,
    'who', 'Owners whose page is live. Each tip is set off by what that owner has or has not done, '
           || 'so every email is about their own page.',
    'when', 'Once a day at 09:47 UTC. At most one tip a week per owner, none from the 1st to the 10th '
            || '(the monthly email''s week) or within 5 days after a monthly email. Sent from spaces@nomadwise.io.',
    'leaves', 'Nobody leaves for good: a tip goes only when it fits. Switch a space off here, or the owner '
              || 'unsubscribes (link in the footer, or Tips for your page in Settings).',
    'start_title', 'Page is live',
    'start_text', 'The owner''s page is on nomadwise.io. From here each tip waits for its moment.',
    'end_title', 'Nothing more to send',
    'end_text', 'Each tip goes once (since you last looked at most every 30 days), and stops when the owner '
                || 'has done what it suggests.',
    'steps', (select coalesce(jsonb_agg(jsonb_build_object(
                'step', st.step, 'enabled', st.enabled,
                'updated_at', st.updated_at, 'updated_by', st.updated_by,
                'when', case st.step
                  when 1 then '3 to 21 days after their changes (or page) went live, when the page is not complete. Once for each missing thing'
                  when 2 then 'The day their page becomes complete (photos, opening hours, description, prices, Wi-Fi). Once'
                  when 3 then '30 days without signing in or sending an edit, when their page had something to show. At most every 30 days'
                  else '1 to 7 days after the first request ever sent to them. Once' end,
                'subject', replace(t.subject, '{{subject_prefix}}', ''),
                'body', t.text_body,
                'button', case st.step when 2 then 'See my page' when 1 then '{{next_button}}' else 'Open my Owner account' end,
                'sent', (select count(*) from public.owner_emails o
                          where o.kind = case st.step when 1 then 'tip_next' when 2 then 'tip_complete'
                                                      when 3 then 'tip_quiet' else 'tip_first_request' end))
                order by st.step), '[]'::jsonb)
                from public.sequence_steps st
                join public.email_templates t on t.alias = case st.step when 1 then 'tip-next' when 2 then 'tip-complete'
                                                                         when 3 then 'tip-quiet' else 'tip-first-request' end
               where st.sequence_key = 'owner_tips'),
    'spaces', spaces);
end $$;
revoke all on function public.owner_tips_sequence() from public, anon, authenticated;

-- Sequences lists the tips after the sign-in reminders.
select public.pm_patch_fn('public.admin_sequences()',
  $a$from public.signin_reminder_spaces() s)));$a$,
  $a$from public.signin_reminder_spaces() s)), public.owner_tips_sequence());$a$,
  $m$public.owner_tips_sequence()$m$);
