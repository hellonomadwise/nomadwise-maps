-- Migration 167: sequences, starting with reminders for owners who
-- claimed and never signed in; and no notice for an email system that
-- checks the link in our message.
--
-- 1. Jonathan, 8 Oct 2026, with Workspace 6 and Place Coworking
--    Phuket in Outreach ("Owner account: not signed in yet"): "would
--    it make sense to setup a sequence, for these spaces where they
--    have claimed, but haven't yet logged in, like after 7 days ...
--    just a super friendly reminder, to the email address on file?"
--    He chose two: day 7 and day 21, with the words shown to him.
--    And: "clearly illustrate it within the Nomad Maps admin area ...
--    know exactly what spaces are included in sequencing and what the
--    sequencing route is and also for the ability for us to switch
--    that off ... either all together or for each individual email or
--    listing". So a sequence is a thing of its own, with a switch for
--    the whole of it, one for each email, and one for each space,
--    shown under Sequences in the team tools.
--
--      sequences             one row per sequence, with its switch
--      sequence_steps        its emails, each with a switch
--      sequence_exclusions   spaces switched off for a sequence
--      sequence_sends        what went, to whom, when (each once)
--
--    "Owner sign-in reminders" (signin_reminders):
--      who:   a space whose owner claimed it themselves (not one we set
--             up), with the claim approved in the last 90 days, the
--             owner's address still the one on the space, not one of
--             our tests, not unsubscribed, never been into the Owner
--             account since claiming
--      email 1  7 days after the claim (and at least 2 after approval)
--      email 2  21 days after the claim (and at least 10 after email 1)
--      leaves:  on signing in, when switched off for the space, on
--               unsubscribing, after email 2
--    The emails go once a day (08:10 UTC, 09:10 London in summer) from
--    hello@ through the same sender as the other owner emails, so
--    hello@ gets its copy and they are in the email log. The phones
--    are told what went.
--
-- 2. 8 Oct 2026, 09:42: "Claim page opened for "ffgbavb-gbyyvaa-
--    jbexybae-abuyf", from "email". Looking from Dublin, Ireland ...
--    a VPN or a data centre", minutes after we wrote to Workland Fahle
--    (estonia-tallinn-workland-fahle: the same lengths, letters
--    changed). That is the receiving email system checking the link
--    before the person sees it: such systems work from data centres
--    and alter the link so that nothing is set off. Two more came at
--    09:49 from the Netherlands, one of them not marked as a data
--    centre, so the altered link itself is the sign: a person who
--    follows our link arrives with the space's name as we wrote it. A
--    claim visit that names no space we know and says it came from our
--    email, WhatsApp, Instagram or Facebook message now tells nobody
--    (it is still kept with the claim visits).

create table if not exists public.sequences (
  key        text primary key,
  name       text not null,
  enabled    boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.sequences enable row level security;

create table if not exists public.sequence_steps (
  sequence_key text not null references public.sequences(key) on delete cascade,
  step         smallint not null,
  enabled      boolean not null default true,
  updated_at   timestamptz not null default now(),
  updated_by   text,
  primary key (sequence_key, step)
);
alter table public.sequence_steps enable row level security;

create table if not exists public.sequence_exclusions (
  sequence_key text not null references public.sequences(key) on delete cascade,
  venue_id     uuid not null references public.venues(id) on delete cascade,
  excluded_at  timestamptz not null default now(),
  excluded_by  text,
  primary key (sequence_key, venue_id)
);
alter table public.sequence_exclusions enable row level security;

create table if not exists public.sequence_sends (
  sequence_key text not null,
  step         smallint not null,
  venue_id     uuid not null references public.venues(id) on delete cascade,
  owner_email  text not null,
  sent_at      timestamptz not null default now(),
  primary key (sequence_key, step, venue_id, owner_email)
);
alter table public.sequence_sends enable row level security;

insert into public.sequences (key, name, enabled)
values ('signin_reminders', 'Owner sign-in reminders', true)
on conflict (key) do nothing;
insert into public.sequence_steps (sequence_key, step, enabled)
values ('signin_reminders', 1, true), ('signin_reminders', 2, true)
on conflict (sequence_key, step) do nothing;

-- The words of the two emails, in one place: what is sent, and what
-- the team tools show. (As Jonathan saw and chose them, 8 Oct 2026.)
create or replace function public.signin_reminder_text(
  p_step integer, p_first text, p_space text, p_url text)
returns table (subject text, body text)
language sql immutable as $$
  select
    case when p_step = 1
         then 'Your Owner account for ' || p_space || ' is ready'
         else 'Anything we can help with for ' || p_space || '?' end,
    case when p_step = 1 then
           'Hi ' || p_first || ',' || E'\n\n'
           || 'A quick reminder that ' || p_space || ' is yours to manage on Nomadwise.'
           || coalesce(' Your page: ' || nullif(btrim(coalesce(p_url, '')), ''), '') || E'\n\n'
           || 'Your Owner account is here: https://nomadmaps.io/owner' || E'\n'
           || 'Sign in with this email address. There is no password: we send you a sign-in link.'
           || E'\n\n'
           || 'Once you are in, you can update your opening hours and contact details, '
           || 'and add your own photos, description and prices.' || E'\n\n'
           || 'If anything is unclear, just reply to this email.' || E'\n\n'
           || 'Jonathan'
         else
           'Hi ' || p_first || ',' || E'\n\n'
           || 'Just checking in: you have not signed in to your Owner account for '
           || p_space || ' yet. If something got in the way, reply and tell me and I will '
           || 'sort it out.' || E'\n\n'
           || 'This is the last reminder we send.' || E'\n\n'
           || 'Jonathan' end;
$$;
revoke all on function public.signin_reminder_text(integer, text, text, text) from public, anon, authenticated;

-- Every space the sequence has to do with, and where it stands.
--   status: due (goes at the next daily run), waiting, done (both
--   emails went), signed_in (has been into the Owner account: left),
--   off (switched off for this space), unsubscribed, none (no email of
--   the sequence is switched on for it any more)
create or replace function public.signin_reminder_spaces()
returns table (
  venue_id     uuid,
  name         text,
  city         text,
  country      text,
  owner_name   text,
  owner_email  text,
  claimed_at   timestamptz,
  approved_at  timestamptz,
  sent_1       timestamptz,
  sent_2       timestamptz,
  signed_in_at timestamptz,
  status       text,
  next_step    integer,
  next_at      timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  on1 boolean := coalesce((select s.enabled from public.sequence_steps s
                            where s.sequence_key = 'signin_reminders' and s.step = 1), false);
  on2 boolean := coalesce((select s.enabled from public.sequence_steps s
                            where s.sequence_key = 'signin_reminders' and s.step = 2), false);
begin
  return query
  with base as (
    select v.id as vid, v.name as vname, v.city as vcity, v.country as vcountry,
           a.owner_email as em, a.signed_in_at as signed, coalesce(a.opens, 0) as opens,
           k.owner_name as oname, k.created_at as claimed,
           coalesce(k.approved_at, k.paid_at, k.created_at) as approved,
           (select x.sent_at from public.sequence_sends x
             where x.sequence_key = 'signin_reminders' and x.step = 1
               and x.venue_id = v.id and x.owner_email = a.owner_email) as s1,
           (select x.sent_at from public.sequence_sends x
             where x.sequence_key = 'signin_reminders' and x.step = 2
               and x.venue_id = v.id and x.owner_email = a.owner_email) as s2,
           exists (select 1 from public.sequence_exclusions e
                    where e.sequence_key = 'signin_reminders' and e.venue_id = v.id) as excluded,
           exists (select 1 from public.space_contacts c
                    where c.venue_id = v.id and c.unsubscribed_at is not null) as unsub
      from public.outreach_owner_activity() a
      join public.venues v on v.id = a.venue_id
      join lateral (
        select kk.* from public.listing_claims kk
         where kk.venue_id = v.id
           and lower(btrim(kk.owner_email)) = a.owner_email
           and kk.status in ('paid', 'free')
         order by kk.created_at
         limit 1) k on true
     where a.owner_email is not null
       and not coalesce(a.test, false)
       and coalesce(a.claimed_self, false)
       and (k.created_at > now() - interval '90 days'
            or exists (select 1 from public.sequence_sends x
                        where x.sequence_key = 'signin_reminders' and x.venue_id = v.id))
  ), staged as (
    select b.*,
           case when b.s1 is null and b.s2 is null and on1 then 1
                when b.s2 is null and on2 then 2 end as nstep
      from base b
  )
  select s.vid, s.vname, s.vcity, s.vcountry, s.oname, s.em, s.claimed, s.approved,
         s.s1, s.s2, s.signed,
         case when s.signed is not null or s.opens > 0 then 'signed_in'
              when s.excluded then 'off'
              when s.unsub then 'unsubscribed'
              when s.s2 is not null then 'done'
              when s.nstep is null then case when s.s1 is not null then 'done' else 'none' end
              when (case s.nstep
                      when 1 then greatest(s.claimed + interval '7 days', s.approved + interval '2 days')
                      else greatest(s.claimed + interval '21 days',
                                    coalesce(s.s1 + interval '10 days', s.claimed + interval '21 days'))
                    end) <= now() then 'due'
              else 'waiting' end,
         s.nstep,
         case s.nstep
           when 1 then greatest(s.claimed + interval '7 days', s.approved + interval '2 days')
           when 2 then greatest(s.claimed + interval '21 days',
                                coalesce(s.s1 + interval '10 days', s.claimed + interval '21 days'))
         end
    from staged s
   order by s.claimed desc;
end $$;
revoke all on function public.signin_reminder_spaces() from public, anon, authenticated;

-- Once a day: whatever is due goes, if the sequence and that email are
-- switched on. Each email to each owner once.
create or replace function public.signin_reminders_run()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r     record;
  t     record;
  n     integer := 0;
  names text[] := '{}';
  first text;
begin
  if not coalesce((select s.enabled from public.sequences s where s.key = 'signin_reminders'), false) then
    return 0;
  end if;
  for r in select * from public.signin_reminder_spaces() x where x.status = 'due' loop
    begin
      if not coalesce((select s.enabled from public.sequence_steps s
                        where s.sequence_key = 'signin_reminders' and s.step = r.next_step), false) then
        continue;
      end if;
      insert into public.sequence_sends (sequence_key, step, venue_id, owner_email)
      values ('signin_reminders', r.next_step, r.venue_id, r.owner_email)
      on conflict do nothing;
      if not found then
        continue;
      end if;
      first := coalesce(nullif(split_part(btrim(coalesce(r.owner_name, '')), ' ', 1), ''), 'there');
      select * into t from public.signin_reminder_text(
        r.next_step, first, coalesce(r.name, 'your space'), public.owner_page_url(r.venue_id));
      perform public.send_owner_email(
        r.owner_email, t.subject, t.body, 'signin_reminder_' || r.next_step, r.venue_id::text,
        'Open my Owner account', 'https://nomadmaps.io/owner');
      n := n + 1;
      names := names || (coalesce(r.name, 'a space') || ' (email ' || r.next_step || ')');
    exception when others then
      -- one space must not stop the others; tried again tomorrow
      null;
    end;
  end loop;
  if n > 0 then
    perform public.notify_phone(
      'Sign-in reminders sent',
      n || case when n = 1 then ' reminder' else ' reminders' end || ' went to owners who '
        || 'have not been into their Owner account: ' || array_to_string(names, ', ') || '.',
      'envelope');
  end if;
  return n;
end $$;
revoke all on function public.signin_reminders_run() from public, anon, authenticated;
grant execute on function public.signin_reminders_run() to service_role;

do $$
begin
  perform cron.unschedule('signin-reminders');
exception when others then null;
end $$;
select cron.schedule('signin-reminders', '10 8 * * *', 'select public.signin_reminders_run()');

-- ------------------------------------------------ for the team tools
create or replace function public.admin_sequences()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  seq public.sequences%rowtype;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into seq from public.sequences where key = 'signin_reminders';
  return jsonb_build_array(jsonb_build_object(
    'key', seq.key,
    'name', seq.name,
    'enabled', seq.enabled,
    'updated_at', seq.updated_at,
    'updated_by', seq.updated_by,
    'who', 'Spaces whose owner claimed the page themselves, with the claim approved in the '
           || 'last 90 days, who have never been into their Owner account since.',
    'when', 'Once a day, at 09:10 London time (08:10 UTC). From hello@nomadwise.io, '
            || 'with a copy to hello@.',
    'leaves', 'They leave the sequence when they sign in, when it is switched off for '
              || 'their space, when they unsubscribe, or after the second email.',
    'steps', (select coalesce(jsonb_agg(jsonb_build_object(
                'step', st.step,
                'enabled', st.enabled,
                'updated_at', st.updated_at,
                'updated_by', st.updated_by,
                'when', case st.step when 1 then 'Day 7 after claiming (at least 2 days after approval)'
                                     else 'Day 21 after claiming (at least 10 days after email 1)' end,
                'subject', tx.subject,
                'body', tx.body,
                'button', 'Open my Owner account',
                'sent', (select count(*) from public.sequence_sends x
                          where x.sequence_key = seq.key and x.step = st.step))
                order by st.step), '[]'::jsonb)
                from public.sequence_steps st
                cross join lateral public.signin_reminder_text(
                  st.step, '{first name}', '{space}', '{page link}') tx
               where st.sequence_key = seq.key),
    'spaces', (select coalesce(jsonb_agg(to_jsonb(s) order by
                 case s.status when 'due' then 0 when 'waiting' then 1 when 'none' then 2
                               when 'off' then 3 when 'done' then 4 when 'signed_in' then 5
                               else 6 end,
                 s.next_at nulls last, s.claimed_at desc), '[]'::jsonb)
                 from public.signin_reminder_spaces() s)));
end $$;
revoke all on function public.admin_sequences() from public, anon;
grant execute on function public.admin_sequences() to authenticated;

-- Switch a sequence (p_step null) or one of its emails on or off.
create or replace function public.admin_sequence_set(p_key text, p_step integer, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  who text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  who := (select u.email from auth.users u where u.id = auth.uid());
  if p_step is null then
    update public.sequences
       set enabled = coalesce(p_enabled, false), updated_at = now(), updated_by = who
     where key = p_key;
  else
    update public.sequence_steps
       set enabled = coalesce(p_enabled, false), updated_at = now(), updated_by = who
     where sequence_key = p_key and step = p_step;
  end if;
  if not found then raise exception 'No such sequence or email.'; end if;
end $$;
revoke all on function public.admin_sequence_set(text, integer, boolean) from public, anon;
grant execute on function public.admin_sequence_set(text, integer, boolean) to authenticated;

-- Switch a sequence off (p_off true) or back on for one space.
create or replace function public.admin_sequence_exclude(p_key text, p_venue uuid, p_off boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if not exists (select 1 from public.sequences where key = p_key) then
    raise exception 'No such sequence.';
  end if;
  if coalesce(p_off, false) then
    insert into public.sequence_exclusions (sequence_key, venue_id, excluded_by)
    values (p_key, p_venue, (select u.email from auth.users u where u.id = auth.uid()))
    on conflict do nothing;
  else
    delete from public.sequence_exclusions where sequence_key = p_key and venue_id = p_venue;
  end if;
end $$;
revoke all on function public.admin_sequence_exclude(text, uuid, boolean) from public, anon;
grant execute on function public.admin_sequence_exclude(text, uuid, boolean) to authenticated;

-- ------------------------------------------------ 2. the claim page ping
-- As migration 164, and an email system checking our link tells nobody.
create or replace function public.claim_opened(
  p_seed text, p_from text, p_referrer text, p_user_agent text,
  p_geo jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  seed   text := nullif(left(trim(coalesce(p_seed, '')), 200), '');
  frm    text := nullif(left(trim(coalesce(p_from, '')), 300), '');
  ref    text := nullif(left(trim(coalesce(p_referrer, '')), 300), '');
  ua     text := nullif(left(trim(coalesce(p_user_agent, '')), 300), '');
  g      jsonb := case when jsonb_typeof(p_geo) = 'object' then p_geo else '{}'::jsonb end;
  v_id   uuid;
  v_name text;
  v_city text;
  what   text;
  whence text;
  recent int;
  g_cc      text;
  g_country text;
  g_city    text;
  g_lat     double precision;
  g_lng     double precision;
  g_clock   text;
  g_dc      boolean;
  g_visit   text;
  g_anon    text;
  g_near    text;
  g_src     text;
  g_km      integer;
  title     text := 'Claim page opened';
  place     text := '';
  via       text;      -- it followed our own message
  ours      boolean := false;
  marked    boolean := false;
begin
  -- A blocked network (migration 164): nothing is kept, nobody is
  -- told. The check can never stop a real visit: if it fails, the
  -- visit goes on as before.
  begin
    if public.bot_guard_note(
         nullif(left(btrim(coalesce(g ->> 'anon', '')), 120), ''),
         public.request_ip()) is not null then
      return;
    end if;
  exception when others then
    null;
  end;

  insert into public.claim_visits (seed, from_path, referrer, user_agent)
  values (seed, frm, ref, ua);

  select count(*) into recent from public.claim_visits
   where created_at > now() - interval '1 hour';
  if recent > 30 then
    return;
  end if;

  if seed is not null then
    select id, name, city into v_id, v_name, v_city from public.venues
     where webflow_slug = seed or lower(name) = lower(seed)
     order by coalesce(webflow_slug = seed, false) desc,
              (webflow_cms_id is not null) desc, id
     limit 1;
  end if;
  -- An email system checking the link in one of our messages before
  -- the person sees it (8 Oct 2026: "for "ffgbavb-gbyyvaa-jbexybae-
  -- abuyf"", from "email", from Dublin and the Netherlands, minutes
  -- after we wrote to Workland Fahle). Such systems change letters in
  -- the link so that nothing is set off, so the space it names matches
  -- none; a person following our link arrives with the name as we
  -- wrote it. Not a person: nobody is told.
  if v_id is null and seed is not null
     and lower(coalesce(frm, '')) in ('whatsapp', 'email', 'instagram', 'facebook') then
    return;
  end if;

  -- The space's line in Outreach, so the visit can be followed up
  -- from there (migration 153). Never in the way of the ping.
  begin
    if v_id is not null then
      perform public.outreach_line_for_venue(v_id);
    end if;
  exception when others then
    null;
  end;

  -- Did it follow our own message? The link we send says where it was
  -- sent (believed only for a space we have written to); without
  -- that, a visit straight to the claim page, or out of a mail or
  -- WhatsApp page, within three days of our writing to the space is
  -- taken as an answer too. Not from a data centre: that is a
  -- machine more often than a person.
  begin
    if v_id is not null and lower(coalesce(frm, '')) in ('whatsapp', 'email', 'instagram', 'facebook')
       and exists (select 1 from public.space_contacts s
                    where s.venue_id = v_id and not s.is_test
                      and s.last_out_at > now() - interval '60 days') then
      via := lower(frm);
    elsif v_id is not null and frm is null
          and coalesce(g ->> 'dc', '') <> 'true'
          and (ref is null
               or ref ~* '^https?://([a-z0-9-]+[.])*(mail[.]google[.]com|outlook[.]live[.]com|outlook[.]office[.]com|mail[.]yahoo[.]com|mail[.]proton[.]me|wa[.]me|whatsapp[.]com)(/|$)'
               or ref ~* '^android-app://(com[.]google[.]android[.]gm|com[.]whatsapp)')
          and exists (select 1 from public.space_contacts s
                       where s.venue_id = v_id and not s.is_test
                         and s.last_out_at > now() - interval '3 days') then
      via := 'after';
    end if;
    -- One of our own devices: only a device that has been signed in
    -- as a founder counts (anyone can send the "internal" mark, so it
    -- is mentioned and nothing more).
    ours := exists (select 1 from public.team_devices t
                     where t.anon_id = nullif(btrim(coalesce(g ->> 'anon', '')), ''));
    marked := coalesce(g ->> 'internal', '') = 'true';
  exception when others then
    via := null; ours := false; marked := false;
  end;

  -- Where the visitor was. Never in the way of the ping either.
  begin
    g_cc := upper(left(btrim(coalesce(g ->> 'cc', '')), 2));
    if g_cc !~ '^[A-Z]{2}$' then
      -- what the server itself saw of the request
      begin
        g_cc := upper(btrim(coalesce(
          current_setting('request.headers', true)::json ->> 'cf-ipcountry', '')));
      exception when others then
        g_cc := '';
      end;
    end if;
    if g_cc !~ '^[A-Z]{2}$' or g_cc in ('XX', 'T1') then
      g_cc := null;
    end if;
    -- (what the visitor's browser sent ends up in a notice: letters,
    -- digits and a few marks only, and not much of it)
    g_country := nullif(left(btrim(regexp_replace(coalesce(g ->> 'country', ''),
                   '[^[:alnum:] .,''()-]', '', 'g')), 40), '');
    if g_country is null then
      g_country := public.claim_geo_country(g_cc);
    end if;
    g_city := nullif(left(btrim(regexp_replace(coalesce(g ->> 'city', ''),
                '[^[:alnum:] .,''()-]', '', 'g')), 40), '');
    if (g ->> 'lat') ~ '^-?[0-9]{1,3}([.][0-9]{1,12})?$' then
      g_lat := (g ->> 'lat')::double precision;
    end if;
    if (g ->> 'lng') ~ '^-?[0-9]{1,3}([.][0-9]{1,12})?$' then
      g_lng := (g ->> 'lng')::double precision;
    end if;
    select t.iso into g_clock from public.tz_countries t
     where t.tz = left(btrim(coalesce(g ->> 'tz', '')), 64);
    g_dc := coalesce(g ->> 'dc', '') = 'true';
    -- a town says nothing without its country
    if g_cc is null then
      g_city := null; g_country := null; g_lat := null; g_lng := null;
    end if;
    g_visit := nullif(left(btrim(coalesce(g ->> 'visit', '')), 80), '');
    g_anon := nullif(left(btrim(coalesce(g ->> 'anon', '')), 120), '');
    if g_cc is not null or g_city is not null or g_clock is not null then
      if v_id is not null then
        select j.near, j.src, j.km into g_near, g_src, g_km
          from public.claim_geo_judge(v_id, g_cc, g_city, g_lat, g_lng, g_clock) j;
        if g_visit is not null then
          insert into public.claim_visit_geo
            (visit, anon_id, venue_id, cc, country, city, km, clock_cc, near, src, dc, via)
          values (g_visit, g_anon, v_id, g_cc, g_country, g_city, g_km, g_clock,
                  g_near, g_src, g_dc, via)
          on conflict (visit) do nothing;
        end if;
      end if;
      place := public.claim_visit_words(via, g_near, g_src, g_city, g_country, g_cc, g_clock, g_dc);
      -- (a VPN's or a data centre's place does not go in the title,
      -- and nor does the place of an answer to our own message)
      if via is null and not (g_dc and coalesce(g_src, 'ip') = 'ip') then
        title := case g_near when 'near' then 'Claim page opened, from nearby'
                             when 'country' then 'Claim page opened, same country'
                             when 'far' then 'Claim page opened, from abroad'
                             else title end;
      end if;
    end if;
  exception when others then
    place := ''; title := 'Claim page opened';
  end;
  -- An answer to our message says so even when nothing is known of
  -- the place; and one of our own devices says that, with the place
  -- as a plain fact. Never in the way of the ping.
  begin
    if ours then
      title := 'Claim page opened (one of ours)';
      place := btrim(coalesce(public.claim_geo_words(
                 null, null, g_city, g_country, g_cc, null, false), '')
               || ' This is one of our own devices.');
    elsif via is not null then
      if coalesce(place, '') = '' then
        place := public.claim_visit_words(via, null, null, null, null, null, null,
                                          coalesce(g ->> 'dc', '') = 'true');
      end if;
      if coalesce(g ->> 'dc', '') <> 'true' then
        title := case via when 'whatsapp' then 'Claim page opened, from our WhatsApp'
                          when 'email' then 'Claim page opened, from our email'
                          when 'instagram' then 'Claim page opened, from our Instagram message'
                          when 'facebook' then 'Claim page opened, from our Facebook message'
                          else 'Claim page opened, after our message' end;
      end if;
    end if;
    if marked and not ours then
      place := btrim(coalesce(place, '')
                     || ' The browser is marked as one of ours (not checked).');
    end if;
  exception when others then
    null;
  end;

  what := case when v_name is not null
               then ' for ' || v_name || coalesce(' in ' || nullif(v_city, ''), '')
               when seed is not null then ' for "' || seed || '"'
               else '' end;
  whence := case when via = 'whatsapp' then 'through the link in our WhatsApp message'
                 when via = 'email' then 'through the link in our email'
                 when via = 'instagram' then 'through the link in our Instagram message'
                 when via = 'facebook' then 'through the link in our Facebook message'
                 when frm like '/%' then 'from nomadwise.io' || frm
                 when frm is not null then 'from "' || frm || '"'
                 when ref is not null then 'from ' ||
                      regexp_replace(ref, '^https?://(www[.])?', '')
                 else 'direct, no referrer' end;

  perform public.notify_phone(
    title,
    'Someone opened the claim page' || what || ', ' || whence || '.'
      || case when coalesce(place, '') <> '' then ' ' || place else '' end,
    'eyes');
end $$;
revoke all on function public.claim_opened(text, text, text, text, jsonb) from public;
grant execute on function public.claim_opened(text, text, text, text, jsonb) to anon, authenticated;
