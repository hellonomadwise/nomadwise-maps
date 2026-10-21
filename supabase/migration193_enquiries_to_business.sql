-- ============================================================
-- Migration 193: enquiries become business.
--
-- Jonathan, 21 Oct 2026, on six "Research Form" emails from one nomad
-- (Ellie, a team of two, asking six spaces in Ho Chi Minh City):
-- "build into a flow to be able to turn this into business ... serve
-- this customer getting them what they're looking for, so we can
-- either get a share or gain a verified subscription". Agreed:
--
-- 1. One customer, one card. Enquiries from the same person are passed
--    on together (the control centre groups them) and the nomad gets
--    ONE email listing every space it went to:
--    admin_enquiries_tell_nomad(ids).
-- 2. "Did you find a place?" A few days after passing on, the nomad is
--    asked once where they went, with one link to a small page on
--    nomadmaps.io (?found=<token>) listing the spaces they asked. The
--    answer (that space / still looking / somewhere else) is kept on
--    each enquiry, and the phone is told. This is the evidence a share
--    or Verified needs. OFF until Leonie has approved the wording
--    (sync_settings enquiry_followup, switched in the control centre).
-- 3. "We sent you customers": per space, how many enquiries went to
--    it and how many booked (admin_venue_customers), for Outreach.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

alter table public.enquiries
  add column if not exists followup_token   uuid,
  add column if not exists followup_sent_at timestamptz,
  add column if not exists outcome          text,
  add column if not exists outcome_at       timestamptz,
  add column if not exists outcome_note     text;

do $$
begin
  alter table public.enquiries
    add constraint enquiries_outcome_check
    check (outcome is null or outcome in ('booked', 'not_chosen', 'looking', 'elsewhere'));
exception when duplicate_object then null;
end $$;

create index if not exists idx_enquiries_followup_token
  on public.enquiries (followup_token) where followup_token is not null;
create index if not exists idx_enquiries_passed_at
  on public.enquiries (passed_at) where status = 'passed';

-- Off until Leonie has approved the follow-up wording.
insert into public.sync_settings (key, value)
values ('enquiry_followup', jsonb_build_object('on', false))
on conflict (key) do nothing;

-- ------------------------------------------------ 1. one email to the nomad

-- After several enquiries from one person were passed on together: one
-- email listing every space (instead of one each). Only the ones passed
-- on and not told yet; all must be from the same person.
create or replace function public.admin_enquiries_tell_nomad(p_ids uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em     text;
  nm     text;
  first  text;
  n      integer;
  lines  text;
  sites  boolean;
  ref    uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  if (select count(distinct lower(e.email)) from public.enquiries e
       where e.id = any(p_ids) and e.status = 'passed' and e.nomad_emailed_at is null) > 1 then
    raise exception 'These enquiries are from different people.';
  end if;
  select lower(min(e.email)), min(e.name), count(*), min(e.id::text)::uuid,
         string_agg('- ' || v.name
                    || coalesce(' (' || nullif(btrim(coalesce(v.website, '')), '') || ')', ''),
                    E'\n' order by v.name),
         bool_or(coalesce(btrim(v.website), '') <> '')
    into em, nm, n, ref, lines, sites
    from public.enquiries e
    join public.venues v on v.id = e.venue_id
   where e.id = any(p_ids) and e.status = 'passed' and e.nomad_emailed_at is null;
  if coalesce(n, 0) = 0 then
    return jsonb_build_object('told', 0);
  end if;
  first := nullif(nullif(split_part(btrim(nm), ' ', 1), ''), 'Someone');

  perform public.send_enquiry_mail(
    em, 'hello@nomadwise.io',
    case when n = 1 then 'Your enquiry on nomadwise.io'
         else 'Your enquiry to ' || n || ' spaces on nomadwise.io' end,
    'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
    || 'Thanks for your enquiry on nomadwise.io. We have passed it on to '
    || case when n = 1 then 'this space' else 'these ' || n || ' spaces' end
    || ', and they will reply to you directly at this email address:' || E'\n\n'
    || lines || E'\n\n'
    || case when sites
            then 'If you would like to contact them yourself as well, their websites '
                 || 'are next to their names.' || E'\n\n'
            else '' end
    || 'Enjoy your visit,' || E'\n' || 'Jonathan' || E'\n' || 'Nomadwise',
    'enquiry_passed_nomad', ref::text, null, null);

  update public.enquiries set nomad_emailed_at = now()
   where id = any(p_ids) and status = 'passed' and nomad_emailed_at is null;
  return jsonb_build_object('told', n);
end $$;
revoke all on function public.admin_enquiries_tell_nomad(uuid[]) from public, anon;
grant execute on function public.admin_enquiries_tell_nomad(uuid[]) to authenticated;

-- ------------------------------------------------ 2. did you find a place?

-- "Xom Space", "Xom Space and The Hive", "Xom Space, The Hive and 4
-- other spaces".
create or replace function public.enquiry_space_names(p_names text[])
returns text language sql immutable as $$
  select case coalesce(array_length(p_names, 1), 0)
           when 0 then 'a space'
           when 1 then p_names[1]
           when 2 then p_names[1] || ' and ' || p_names[2]
           when 3 then p_names[1] || ', ' || p_names[2] || ' and ' || p_names[3]
           else p_names[1] || ', ' || p_names[2] || ' and '
                || (array_length(p_names, 1) - 2) || ' other spaces' end;
$$;
revoke all on function public.enquiry_space_names(text[]) from public, anon, authenticated;

-- Daily: once the switch is on, each person whose enquiries were passed
-- on five to twelve days ago (and not asked yet) gets one email. Only
-- enquiries passed on from today, so nobody is asked about an old one.
create or replace function public.enquiry_followup_send()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r     record;
  tok   uuid;
  first text;
  sent  integer := 0;
begin
  if not coalesce((select (value ->> 'on')::boolean from public.sync_settings
                    where key = 'enquiry_followup'), false) then
    return 0;
  end if;
  for r in
    select lower(e.email) as em, min(e.name) as nm,
           array_agg(e.id order by e.passed_at) as ids,
           array_agg(v.name order by e.passed_at) as names
      from public.enquiries e
      join public.venues v on v.id = e.venue_id
     where e.status = 'passed'
       and e.passed_at >= timestamptz '2026-10-21 00:00:00+00'
       and e.passed_at <= now() - interval '5 days'
       and e.passed_at >= now() - interval '12 days'
       and e.followup_sent_at is null
       and e.outcome is null
       and position('@' in coalesce(e.email, '')) > 1
       -- asked at most once a month
       and not exists (select 1 from public.enquiries x
                        where lower(x.email) = lower(e.email)
                          and x.followup_sent_at > now() - interval '30 days')
     group by lower(e.email)
     limit 25
  loop
    tok := gen_random_uuid();
    first := nullif(nullif(split_part(btrim(r.nm), ' ', 1), ''), 'Someone');
    begin
      perform public.send_owner_email(
        r.em,
        'Did you find a place to work?',
        'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
        || 'A few days ago you asked ' || public.enquiry_space_names(r.names)
        || ' on nomadwise.io about working there. Did you find a place?' || E'\n\n'
        || 'It takes one tap to tell us. It helps us know which spaces reply, so we '
        || 'can point other remote workers the right way.' || E'\n\n'
        || 'If you are still looking, reply to this email and I will help you find '
        || 'somewhere.' || E'\n\n'
        || 'Kind regards,' || E'\n' || 'Jonathan' || E'\n' || 'Nomadwise',
        'enquiry_followup', tok::text,
        'Tell us where you went', 'https://nomadmaps.io/?found=' || tok::text);
      update public.enquiries
         set followup_token = tok, followup_sent_at = now()
       where id = any(r.ids);
      sent := sent + 1;
    exception when others then
      null; -- tried again tomorrow
    end;
  end loop;
  return sent;
end $$;
revoke all on function public.enquiry_followup_send() from public, anon, authenticated;
grant execute on function public.enquiry_followup_send() to service_role;

-- The page behind the link: who asked, the spaces they asked, and any
-- answer already given. Anyone with the link (an unguessable key).
create or replace function public.enquiry_followup_view(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  out jsonb;
begin
  if p_token is null then return null; end if;
  select jsonb_build_object(
           'first', nullif(nullif(split_part(btrim(min(e.name)), ' ', 1), ''), 'Someone'),
           'spaces', jsonb_agg(jsonb_build_object(
                       'id', e.id, 'name', v.name, 'city', v.city, 'slug', v.webflow_slug)
                     order by v.name),
           'answer', (select x.outcome from public.enquiries x
                       where x.followup_token = p_token and x.outcome is not null
                       order by (x.outcome = 'booked') desc limit 1),
           'chosen', (select x.id from public.enquiries x
                       where x.followup_token = p_token and x.outcome = 'booked' limit 1))
    into out
    from public.enquiries e
    join public.venues v on v.id = e.venue_id
   where e.followup_token = p_token;
  if out -> 'spaces' is null or jsonb_typeof(out -> 'spaces') <> 'array' then
    return null;
  end if;
  return out;
end $$;
revoke all on function public.enquiry_followup_view(uuid) from public;
grant execute on function public.enquiry_followup_view(uuid) to anon, authenticated;

-- Their answer: 'space' (with the enquiry of the space they chose),
-- 'looking' or 'elsewhere', and a note. Can be changed. The phone is
-- told when the answer is new or different.
create or replace function public.enquiry_followup_answer(
  p_token uuid, p_choice text, p_enquiry uuid default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  was    text;
  nm     text;
  space  text;
  city   text;
  note   text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
begin
  if p_token is null or not exists (select 1 from public.enquiries where followup_token = p_token) then
    raise exception 'This link is not valid any more.';
  end if;
  if (select min(followup_sent_at) from public.enquiries where followup_token = p_token)
       < now() - interval '90 days' then
    raise exception 'This link is not valid any more.';
  end if;
  if coalesce(p_choice, '') not in ('space', 'looking', 'elsewhere') then
    raise exception 'Unknown answer.';
  end if;
  if p_choice = 'space' and not exists (
       select 1 from public.enquiries where followup_token = p_token and id = p_enquiry) then
    raise exception 'Choose one of the spaces.';
  end if;

  select string_agg(coalesce(x.outcome, '') || ':' || x.id::text, ',' order by x.id) into was
    from public.enquiries x where x.followup_token = p_token;

  update public.enquiries e
     set outcome = case when p_choice = 'space'
                        then case when e.id = p_enquiry then 'booked' else 'not_chosen' end
                        else p_choice end,
         outcome_at = now(),
         outcome_note = coalesce(note, e.outcome_note)
   where e.followup_token = p_token;

  -- Tell the phone, unless nothing changed.
  if was is distinct from (select string_agg(coalesce(x.outcome, '') || ':' || x.id::text, ',' order by x.id)
                             from public.enquiries x where x.followup_token = p_token) then
    select min(e.name), min(v.city) into nm, city
      from public.enquiries e left join public.venues v on v.id = e.venue_id
     where e.followup_token = p_token;
    select v.name into space from public.enquiries e join public.venues v on v.id = e.venue_id
     where e.id = p_enquiry and e.followup_token = p_token;
    begin
      perform public.notify_phone(
        case p_choice when 'space' then 'A customer booked'
                      when 'looking' then 'A customer is still looking'
                      else 'A customer went elsewhere' end,
        coalesce(nullif(split_part(btrim(nm), ' ', 1), ''), 'Someone')
          || case p_choice when 'space' then ' went with ' || coalesce(space, 'a space')
                           when 'looking' then ' is still looking' || coalesce(' in ' || nullif(city, ''), '')
                           else ' found somewhere else' end
          || coalesce(': "' || left(note, 100) || '"', '')
          || case when p_choice = 'looking' then '. Reply to their email to help.' else '.' end,
        case when p_choice = 'space' then 'tada' else 'bell' end);
    exception when others then null;
    end;
  end if;
  return public.enquiry_followup_view(p_token);
end $$;
revoke all on function public.enquiry_followup_answer(uuid, text, uuid, text) from public;
grant execute on function public.enquiry_followup_answer(uuid, text, uuid, text) to anon, authenticated;

-- The switch, for the control centre (on once Leonie has approved).
create or replace function public.admin_enquiry_followup_set(p_on boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  insert into public.sync_settings (key, value)
  values ('enquiry_followup', jsonb_build_object('on', coalesce(p_on, false)))
  on conflict (key) do update set value = excluded.value;
  return coalesce(p_on, false);
end $$;
revoke all on function public.admin_enquiry_followup_set(boolean) from public, anon;
grant execute on function public.admin_enquiry_followup_set(boolean) to authenticated;

do $$
begin
  perform cron.unschedule('enquiry-followup');
exception when others then null;
end $$;
select cron.schedule('enquiry-followup', '7 9 * * *',
  'select public.enquiry_followup_send()');

-- ------------------------------------------------ 3. we sent you customers

-- Per space: enquiries that reached it (passed on by us, or sent
-- straight to a Verified space), how many booked, and the last one.
create or replace function public.admin_venue_customers()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return coalesce((
    select jsonb_object_agg(t.venue_id::text, jsonb_build_object(
             'sent', t.sent, 'booked', t.booked, 'last', t.last_at))
      from (select e.venue_id,
                   count(*) as sent,
                   count(*) filter (where e.outcome = 'booked') as booked,
                   max(coalesce(e.passed_at, e.sent_at)) as last_at
              from public.enquiries e
             where e.venue_id is not null and e.status in ('passed', 'sent')
             group by e.venue_id) t), '{}'::jsonb);
end $$;
revoke all on function public.admin_venue_customers() from public, anon;
grant execute on function public.admin_venue_customers() to authenticated;

-- The Enquiries list (migration 113's), plus: bookings in the last 30
-- days, the follow-up switch, and the latest answers.
create or replace function public.admin_enquiries_to_pass_on()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return jsonb_build_object(
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'name', e.name, 'email', e.email, 'phone', e.phone,
               'message', e.message, 'dates', e.dates, 'created_at', e.created_at,
               'listing_text', e.listing_text, 'source', e.source,
               'venue_id', v.id, 'venue_name', v.name, 'city', v.city,
               'slug', v.webflow_slug, 'website', v.website, 'instagram', v.instagram,
               'tier', coalesce(v.listing_tier, 'free'),
               'owner_email', v.listing_owner_email,
               'contact_emails', coalesce(to_jsonb(v.contact_emails), '[]'::jsonb),
               'contact_checked', v.contact_checked_at is not null,
               'earlier', (select count(*) from public.enquiries x
                            where x.venue_id = e.venue_id and x.id <> e.id))
             order by e.created_at)
        from public.enquiries e
        left join public.venues v on v.id = e.venue_id
       where e.status = 'waiting'), '[]'::jsonb),
    'passed_30d', (select count(*) from public.enquiries
                    where status = 'passed' and passed_at > now() - interval '30 days'),
    'direct_30d', (select count(*) from public.enquiries
                    where status = 'sent' and sent_at > now() - interval '30 days'),
    'booked_30d', (select count(*) from public.enquiries
                    where outcome = 'booked' and outcome_at > now() - interval '30 days'),
    'followup_on', coalesce((select (value ->> 'on')::boolean from public.sync_settings
                              where key = 'enquiry_followup'), false),
    'answers', coalesce((
      select jsonb_agg(a order by a ->> 'at' desc)
        from (select jsonb_build_object(
                       'name', min(e.name),
                       'outcome', case when bool_or(e.outcome = 'booked') then 'booked'
                                       else min(e.outcome) end,
                       'space', (select v2.name from public.enquiries e2
                                  join public.venues v2 on v2.id = e2.venue_id
                                 where e2.followup_token = e.followup_token
                                   and e2.outcome = 'booked' limit 1),
                       'asked', count(*),
                       'note', max(e.outcome_note),
                       'at', max(e.outcome_at)) as a
                from public.enquiries e
               where e.followup_token is not null and e.outcome is not null
               group by e.followup_token
               order by max(e.outcome_at) desc
               limit 8) s), '[]'::jsonb),
    'import', (select value from public.sync_settings where key = 'enquiry_import'));
end $$;
revoke all on function public.admin_enquiries_to_pass_on() from public, anon;
grant execute on function public.admin_enquiries_to_pass_on() to authenticated;

notify pgrst, 'reload schema';
