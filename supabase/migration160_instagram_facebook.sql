-- Migration 160: a message on Instagram or Facebook, when there is no
-- WhatsApp number.
--
-- "Looked at the claim page" offered WhatsApp, or an email when we
-- hold an address. Many cafes have neither on record, and Google's
-- number for a place is often a landline. Jonathan, 7 Oct 2026: "if
-- WhatsApp isn't available, maybe their Facebook page, or Instagram as
-- an option". Neither lets a message be written from outside, so the
-- app copies the words, opens their page, and the founder pastes and
-- sends; nothing is sent from here.
--
--   admin_outreach_log_message(id, body, channel, at)
--        records what was sent by hand on WhatsApp, Instagram or
--        Facebook, like the WhatsApp one of migration 156 (kept, so an
--        app from before this still records)
--   claim_visit_words, claim_look_geo, claim_opened
--        as migration 156, and a claim link marked from=instagram or
--        from=facebook is now known as ours too, so the notice says
--        "from our Instagram message" and not "from abroad"

create or replace function public.admin_outreach_log_message(
  p_id uuid, p_body text, p_channel text, p_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c     public.space_contacts%rowtype;
  who   text;
  label text := case lower(coalesce(p_channel, ''))
                  when 'whatsapp' then 'WhatsApp'
                  when 'instagram' then 'Instagram'
                  when 'facebook' then 'Facebook'
                end;
  -- when the page was opened with the message (at most six hours ago)
  sent  timestamptz := greatest(now() - interval '6 hours',
                                least(now(), coalesce(p_at, now())));
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if label is null then
    raise exception 'Unknown channel: %', coalesce(p_channel, '(none)');
  end if;
  select * into c from public.space_contacts where id = p_id for update;
  if not found then raise exception 'Contact not found.'; end if;
  if c.unsubscribed_at is not null then
    raise exception 'They asked us not to write again.';
  end if;
  who := coalesce((select email from auth.users where id = auth.uid()), 'founder');
  insert into public.outreach_messages (contact_id, direction, template_key, subject, body, sent_by, at)
  values (c.id, 'out', 'claim_looked_wa', label, left(coalesce(p_body, ''), 4000),
          who || ' (' || label || ')', sent);
  update public.space_contacts
     set last_out_at = sent,
         stage = case when stage in ('new', 'contacted', 'not_now', 'replied') then 'contacted' else stage end
   where id = c.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_outreach_log_message(uuid, text, text, timestamptz) from public, anon;
grant execute on function public.admin_outreach_log_message(uuid, text, text, timestamptz) to authenticated;

-- ------------------------------------------------ the three functions of
-- migration 156, with Instagram and Facebook beside WhatsApp and email

create or replace function public.claim_visit_words(
  p_via text, p_near text, p_src text, p_city text, p_country text, p_cc text,
  p_clock_cc text, p_dc boolean)
returns text language sql stable security definer set search_path = public as $$
  select case
    when coalesce(p_via, '') = '' then
      public.claim_geo_words(p_near, p_src, p_city, p_country, p_cc, p_clock_cc, p_dc)
    else btrim(
      case
        -- (mail and message services open links to check them, from data centres)
        when p_via in ('whatsapp', 'email', 'instagram', 'facebook') and coalesce(p_dc, false) then
          'It came through the link in our '
          || case p_via when 'whatsapp' then 'WhatsApp message'
                        when 'instagram' then 'Instagram message'
                        when 'facebook' then 'Facebook message'
                        else 'email' end
          || ', but from a data centre or a VPN, so it may be a link checker and not a person.'
        when p_via = 'whatsapp' then 'Most likely the person we wrote to on WhatsApp.'
        when p_via = 'email' then 'Most likely the person we emailed.'
        when p_via = 'instagram' then 'Most likely the person we wrote to on Instagram.'
        when p_via = 'facebook' then 'Most likely the person we wrote to on Facebook.'
        else 'We wrote to this space in the last few days and this visit came straight to the claim page, so it may well be the person we wrote to.'
      end
      || case when s.place is not null then ' They were looking from ' || s.place || '.' else '' end
      || case when s.clock is not null
                   and upper(coalesce(p_clock_cc, '')) <> upper(coalesce(p_cc, ''))
              then ' The device''s clock is on ' || s.clock || ' time.' else '' end)
    end
    from (select public.claim_geo_place(p_city, p_country) as place,
                 public.claim_geo_country(p_clock_cc) as clock) s;
$$;
revoke all on function public.claim_visit_words(text, text, text, text, text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.claim_visit_words(text, text, text, text, text, text, text, boolean)
  to service_role;

create or replace function public.claim_look_geo(p_venue uuid, p_last timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'near', g.near, 'src', g.src, 'km', g.km, 'dc', g.dc, 'at', g.at,
           'via', g.via,
           'place', public.claim_geo_place(g.city, g.country),
           'words', public.claim_visit_words(g.via, g.near, g.src, g.city, g.country,
                                             g.cc, g.clock_cc, g.dc))
    from public.claim_visit_geo g
   where g.venue_id = p_venue
     and g.at > coalesce(p_last, now()) - interval '14 days'
     -- only the visits since we last wrote to the space, or set it
     -- aside: an older one is not what brought it back
     and g.at > coalesce((
           select max(greatest(coalesce(s.last_out_at, '-infinity'::timestamptz),
                               coalesce(s.claim_look_done_at, '-infinity'::timestamptz)))
             from public.space_contacts s
            where s.venue_id = p_venue and not s.is_test), '-infinity'::timestamptz)
     and not exists (select 1 from public.team_devices t where t.anon_id = g.anon_id)
   order by case when g.via in ('whatsapp', 'email', 'instagram', 'facebook') and not g.dc then 0
                 when g.near = 'near' then 1
                 when g.via is not null and not g.dc then 2
                 when g.near = 'country' then 3
                 when g.near = 'far' then 5
                 else 4 end,
            g.dc, g.at desc
   limit 1;
$$;
revoke all on function public.claim_look_geo(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.claim_look_geo(uuid, timestamptz) to service_role;

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
