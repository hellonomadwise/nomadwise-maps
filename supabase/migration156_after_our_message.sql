-- Migration 156: a claim page opened after our own message.
--
-- Jonathan, 7 Oct 2026: he sent Lisbon-Cowork a WhatsApp from Outreach
-- at 13:11 (to the French mobile number Google lists for it), and at
-- 14:12 the phone said "Claim page opened, from abroad... Looking from
-- France, another country: less likely to be the owner". It was the
-- other way round: a visit that comes straight to the claim page an
-- hour after we sent the claim link is most likely the person we
-- wrote to, wherever their connection is.
--
--   * The claim link in what we send from Outreach now says where it
--     was sent (from=whatsapp, from=email), so such a visit is known
--     for what it is.
--   * A visit with no such mark that comes straight to the claim page
--     (no page before it) within three days of our writing to the
--     space is taken as "after our message".
--   * For both, the notice and the card in Outreach say so, and the
--     place is given as a fact. In the list such a look comes first.
--   * "Another country" is said more gently everywhere: a weaker
--     sign, not "less likely to be the owner". The visit above was
--     the owner: he claimed the page three minutes later.
--   * A visit from one of our own devices says so.
--   * Outreach lists the line with the latest activity first (his ask
--     of the same day), whoever acted: before, lines with an address
--     came first.
--   * "I sent it" on WhatsApp counts from when WhatsApp was opened.
--   * Separately: an owner's description may be 8,000 characters (it
--     was 3,000, less than some pages already have).

alter table public.claim_visit_geo
  add column if not exists via text;   -- 'whatsapp', 'email', 'after': it followed our message

-- The sentence for a visit, for the phone notice and for Outreach.
-- p_via: 'whatsapp' or 'email' (it came through the link in what we
-- sent), 'after' (straight to the claim page within three days of our
-- writing), or null, when the place alone is judged (migration 154).
create or replace function public.claim_visit_words(
  p_via text, p_near text, p_src text, p_city text, p_country text, p_cc text,
  p_clock_cc text, p_dc boolean)
returns text language sql stable security definer set search_path = public as $$
  select case
    when coalesce(p_via, '') = '' then
      public.claim_geo_words(p_near, p_src, p_city, p_country, p_cc, p_clock_cc, p_dc)
    else btrim(
      case
        -- (mail services open links to check them, from data centres)
        when p_via in ('whatsapp', 'email') and coalesce(p_dc, false) then
          'It came through the link in our '
          || case p_via when 'whatsapp' then 'WhatsApp message' else 'email' end
          || ', but from a data centre or a VPN, so it may be a link checker and not a person.'
        when p_via = 'whatsapp' then 'Most likely the person we wrote to on WhatsApp.'
        when p_via = 'email' then 'Most likely the person we emailed.'
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

-- As migration 154, with the words above. Of a space's visits the one
-- shown is: through a link we sent; else from the space's own area;
-- else straight after our message; else by place.
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
   order by case when g.via in ('whatsapp', 'email') and not g.dc then 0
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

-- ------------------------------------------------ another country, said more gently
-- As migration 154. The first look from abroad the day this was built
-- was the owner (a French number, a clock on London time, a space in
-- Lisbon), so "less likely to be the owner" said too much.
create or replace function public.claim_geo_words(
  p_near text, p_by text, p_city text, p_country text, p_cc text,
  p_clock_cc text, p_dc boolean)
returns text language sql stable security definer set search_path = public as $$
  select btrim(
    case
      when s.place is null and s.clock is null then ''
      when p_near = 'near' then
        'Looking from ' || coalesce(s.place, 'nearby')
        || ', the space''s own area: quite possibly someone from the space.'
      when p_near = 'country' and coalesce(p_by, 'ip') = 'ip' then
        'Looking from ' || coalesce(s.place, 'the same country')
        || ', the same country as the space: could well be someone from the space.'
      when p_near = 'country' then
        case when s.place is null then 'The device''s clock is on '
             else 'The connection shows ' || s.place || ', but the device''s clock is on ' end
        || s.clock || ' time, the space''s country: probably there'
        || case when s.place is null then '.' else ', through a VPN.' end
      when p_near = 'far' then
        case when s.place is null then 'The device''s clock is on ' || s.clock || ' time'
             else 'Looking from ' || s.place end
        || ', a different country from the space''s. That is a weaker sign, though owners are often abroad.'
      else
        case when s.place is null then '' else 'Looking from ' || s.place || '.' end
    end
    -- the clock, when it tells another story than the connection
    || case when s.place is not null and s.clock is not null
                 and not (coalesce(p_near, '') = 'country' and coalesce(p_by, 'ip') = 'clock')
                 and upper(coalesce(p_clock_cc, '')) <> upper(coalesce(p_cc, ''))
            then ' The device''s clock is on ' || s.clock || ' time.' else '' end
    || case when coalesce(p_dc, false) and coalesce(p_by, 'ip') = 'ip' and s.place is not null
            then ' The connection is a VPN or a data centre, so the place may not be theirs.'
            else '' end)
    from (select public.claim_geo_place(p_city, p_country) as place,
                 public.claim_geo_country(p_clock_cc) as clock) s;
$$;
revoke all on function public.claim_geo_words(text, text, text, text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.claim_geo_words(text, text, text, text, text, text, boolean)
  to service_role;

-- ------------------------------------------------ the claim page notice
-- As migration 154, and it knows a visit that followed our own message,
-- and one of our own devices.
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
    if v_id is not null and lower(coalesce(frm, '')) in ('whatsapp', 'email')
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

-- ------------------------------------------------ the claim link we send
-- As migration 123, with the mark on the claim link.
create or replace function public.admin_outreach_preview(p_id uuid, p_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c   public.space_contacts%rowtype;
  v   public.venues%rowtype;
  t   public.outreach_templates%rowtype;
  first_name text;
  space text;
  city  text;
  page_link text;
  claim_link text;
  price text;
  subj text;
  body text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
  select * into t from public.outreach_templates where key = p_key;
  if not found then raise exception 'No such template.'; end if;
  if c.venue_id is not null then
    select * into v from public.venues where id = c.venue_id;
  end if;

  first_name := coalesce(nullif(split_part(trim(coalesce(c.person_name, '')), ' ', 1), ''), 'there');
  space := coalesce(nullif(trim(c.space_name), ''), v.name, 'your space');
  city  := coalesce(nullif(trim(c.city), ''), v.city, 'your city');
  page_link := case when v.webflow_cms_id is not null and coalesce(v.webflow_slug, '') <> ''
                    then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  -- (from= says where the link was sent, so a visit through it is
  -- known as an answer to our message: migration 156)
  claim_link := 'https://nomadmaps.io/?claim='
             || public.form_enc(coalesce(v.webflow_slug, space))
             || case when right(p_key, 3) = '_wa' then '&from=whatsapp' else '&from=email' end
             || case when c.email is not null then '&email=' || public.form_enc(c.email) else '' end;
  price := case when coalesce(v.country, c.country, '') <> ''
                     and coalesce((public.pricing_for(coalesce(v.country, c.country))->>'ready')::boolean, false)
                then public.verified_price_words(coalesce(v.country, c.country))
                else 'around a day pass a month' end;

  subj := t.subject; body := t.body;
  -- The subject takes the words, not the links.
  subj := replace(subj, '{space}', space);
  subj := replace(subj, '{first_name}', first_name);
  subj := replace(subj, '{name}', coalesce(nullif(trim(c.person_name), ''), 'there'));
  subj := replace(subj, '{city}', city);
  body := replace(body, '{first_name}', first_name);
  body := replace(body, '{name}', coalesce(nullif(trim(c.person_name), ''), 'there'));
  body := replace(body, '{space}', space);
  body := replace(body, '{city}', city);
  body := replace(body, '{page_link}', coalesce(page_link, 'https://www.nomadwise.io'));
  body := replace(body, '{claim_link}', claim_link);
  body := replace(body, '{price_words}', price);
  body := replace(body, '{unsubscribe_link}', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
  body := replace(body, '{signoff}', E'Jonathan\nNomadwise, https://www.nomadwise.io');
  return jsonb_build_object('subject', subj, 'body', body, 'to', c.email,
                            'page_link', page_link, 'claim_link', claim_link,
                            'stream', t.stream,
                            'unsubscribe_link', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
end $$;
revoke all on function public.admin_outreach_preview(uuid, text) from public, anon;
grant execute on function public.admin_outreach_preview(uuid, text) to authenticated;

-- ------------------------------------------------ the list
-- As migration 154, with the order of the looks.
create or replace function public.admin_outreach_list(
  p_stage text default null, p_q text default null, p_limit integer default 200,
  p_group text default null, p_step text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  q  text := lower(trim(coalesce(p_q, '')));
  st text := coalesce(nullif(btrim(p_step), ''), '');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    with act as materialized (
      select y.*, (y.claimed_self or y.accessed) as mine
        from (select a.*,
                     (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
                     (a.signed_in_at is not null or a.opens > 0
                      or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
                from public.outreach_owner_activity() a) y
    ),
    -- somebody opened the claim page and it is still to follow up
    look as materialized (
      select k.*, public.claim_look_geo(k.venue_id, k.last_at) as geo
        from public.claim_look_lines() k
    ),
    -- an account on the map that is plainly this space's
    signup as materialized (
      select * from public.signup_lines()
    )
    select jsonb_agg(row_to_json(x)::jsonb order by x.sort_at desc nulls last, x.sort_first, x.space_name)
      from (
        select c.id, c.venue_id, c.space_name, c.kind, c.city, c.country,
               c.person_name, c.email, c.phone, c.website, c.instagram,
               c.source, c.form_name, c.stage, c.stage_at, c.first_in_at,
               c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.unsubscribed_at, c.is_test,
               (c.email is null) as no_email,
               -- the look's own list: the latest look first, with or
               -- without an address
               (case when st in ('claim_looked', 'form_begun', 'signed_up') then false
                     else c.email is null end) as sort_first,
               -- a look from the space's own area first, then its
               -- country, then not known, then another country
               (case when st in ('claim_looked', 'form_begun')
                     then case l.geo ->> 'near' when 'near' then 0 when 'country' then 1
                                                when 'far' then 3 else 2 end
                     else 0 end) as sort_rank,
               -- The latest thing that happened on the line, whoever did
               -- it: they wrote, we wrote, its stage changed, its claim
               -- page was opened, an account was made, or the owner was
               -- in their Owner account. (Jonathan, 7 Oct 2026: "can
               -- you make most recent activity on top".)
               greatest(coalesce(c.last_in_at, c.created_at), coalesce(c.last_out_at, c.created_at),
                        c.stage_at, l.last_at, su.signed_up_at,
                        a.signed_in_at, a.last_open, a.last_did) as sort_at,
               v.google_place_id as place_id,
               case when l.contact_id is not null then jsonb_build_object(
                 'last_at', l.last_at, 'opens', l.opens, 'visitors', l.visitors,
                 'furthest', l.furthest, 'secs', l.secs, 'from', l.from_path,
                 'referrer', l.referrer, 'device', l.device,
                 'form_email', l.form_email, 'form_name', l.form_name,
                 'geo', l.geo) end as claim_look,
               case when su.contact_id is not null then jsonb_build_object(
                 'email', su.email, 'name', su.display_name,
                 'at', su.signed_up_at, 'how', su.how) end as signup,
               v.name as venue_name, v.city as venue_city, v.country as venue_country,
               v.webflow_slug, (v.webflow_cms_id is not null) as on_site,
               v.listing_tier, v.listing_owner_email,
               (select m.body from public.outreach_messages m
                 where m.contact_id = c.id and m.direction = 'in'
                 order by m.at desc limit 1) as last_in,
               (select count(*) from public.outreach_messages m where m.contact_id = c.id) as message_count,
               case when a.venue_id is not null then jsonb_build_object(
                 'signed_in_at', a.signed_in_at, 'accessed', a.accessed,
                 'opens', a.opens, 'open_days', a.open_days, 'last_open', a.last_open,
                 'edits', a.edits, 'submitted', a.submitted, 'answers', a.answers,
                 'ideas', a.ideas, 'billing', a.billing, 'did', a.did,
                 'last_did', a.last_did, 'looked', a.looked, 'checkout', a.checkout,
                 -- false: we set this space up and they have not claimed it
                 'mine', a.mine) end as owner
          from public.space_contacts c
          left join public.venues v on v.id = c.venue_id
          left join act a on a.venue_id = c.venue_id and c.stage in ('claimed', 'verified')
          left join look l on l.contact_id = c.id
          left join signup su on su.contact_id = c.id
         -- a line marked as a test shows under "Tests" and nowhere else
         where (case when st = '' and coalesce(p_stage, '') = 'tests'
                     then c.is_test else not c.is_test end)
           -- the chips: "Set up by us" has its own, and those lines are
           -- not under Claimed or Verified
           and (st <> '' or coalesce(p_stage, '') in ('', 'tests')
                or (p_stage = 'ours' and coalesce(not a.mine, false))
                or (c.stage = p_stage
                    and not (p_stage in ('claimed', 'verified') and coalesce(not a.mine, false))))
           and (st <> '' or coalesce(p_group, '') = '' or public.outreach_group(c.source) = p_group)
           and (q = '' or lower(coalesce(c.space_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.email, '')) like '%' || q || '%'
                       or lower(coalesce(c.person_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.city, '')) like '%' || q || '%'
                       or lower(coalesce(c.country, '')) like '%' || q || '%'
                       or lower(coalesce(v.name, '')) like '%' || q || '%')
           and (st = '' or case st
                  when 'no_email'    then c.stage = 'new' and c.email is null
                  when 'ready'       then c.stage = 'new' and c.email is not null
                  when 'waiting'     then c.stage = 'contacted'
                  when 'follow_up'   then public.outreach_follow_up_due(
                                            c.stage, c.follow_up_on, c.last_out_at)
                  when 'replied'     then c.stage = 'replied'
                  when 'stepped_off' then c.stage in ('not_now', 'declined', 'unsubscribed', 'bounced')
                  when 'claim_looked' then l.contact_id is not null
                  when 'form_begun'   then l.contact_id is not null and l.form_email is not null
                  when 'signed_up'    then su.contact_id is not null
                  when 'claimed'     then coalesce(a.mine, false)
                  when 'not_opened'  then coalesce(a.mine and not a.accessed, false)
                  when 'ours'        then coalesce(not a.mine, false)
                  when 'opened'      then coalesce(a.accessed, false)
                  when 'opened_only' then coalesce(a.accessed and a.did = 0, false)
                  when 'used'        then coalesce(a.did > 0, false)
                  when 'looked'      then coalesce(a.mine and a.looked, false)
                  when 'verified'    then coalesce(a.mine and a.tier = 'verified', false)
                  else false end)
         order by sort_at desc nulls last, sort_first, space_name
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer, text, text) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer, text, text) to authenticated;

-- ------------------------------------------------ "I sent it" on WhatsApp
-- As migration 153, and it takes the moment WhatsApp was opened with
-- the message: an owner can open the claim link before "I sent it" is
-- pressed, and that look must not count as older than our message.
drop function if exists public.admin_outreach_log_whatsapp(uuid, text);
create or replace function public.admin_outreach_log_whatsapp(
  p_id uuid, p_body text, p_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c   public.space_contacts%rowtype;
  who text;
  -- when WhatsApp was opened with the message (at most six hours ago)
  sent timestamptz := greatest(now() - interval '6 hours',
                               least(now(), coalesce(p_at, now())));
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id for update;
  if not found then raise exception 'Contact not found.'; end if;
  if c.unsubscribed_at is not null then
    raise exception 'They asked us not to write again.';
  end if;
  who := coalesce((select email from auth.users where id = auth.uid()), 'founder');
  insert into public.outreach_messages (contact_id, direction, template_key, subject, body, sent_by, at)
  values (c.id, 'out', 'claim_looked_wa', 'WhatsApp', left(coalesce(p_body, ''), 4000),
          who || ' (WhatsApp)', sent);
  update public.space_contacts
     set last_out_at = sent,
         stage = case when stage in ('new', 'contacted', 'not_now', 'replied') then 'contacted' else stage end
   where id = c.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_outreach_log_whatsapp(uuid, text, timestamptz) from public, anon;
grant execute on function public.admin_outreach_log_whatsapp(uuid, text, timestamptz) to authenticated;

-- ------------------------------------------------ an owner's description: room for the page's own text
-- As migration 78, with 8,000 characters where it kept 3,000. The form
-- opens with the page's own text (migration 135), and a page's text
-- can be longer than 3,000 characters: Lisbon-Cowork's owner could not
-- send in a one-sentence change (7 Oct 2026), and a draft saved here
-- lost the end of its text without a word.
create or replace function public.owner_save_draft(
  p_venue uuid, p_draft jsonb, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em     text := public.owner_email();
  v_name text;
  d      public.owner_drafts%rowtype;
  clean  jsonb;
begin
  if em is null then
    raise exception 'Please sign in.';
  end if;
  select name into v_name from public.venues
   where id = p_venue and lower(listing_owner_email) = em;
  if not found then
    raise exception 'This space is not on your account.';
  end if;
  if pg_column_size(p_draft) > 60000 then
    raise exception 'That is too much text; please shorten it.';
  end if;

  -- Keep only the keys the editor knows, trimmed to sane lengths.
  clean := jsonb_strip_nulls(jsonb_build_object(
    'description', left(coalesce(p_draft->>'description', ''), 8000),
    'prices', jsonb_build_object(
        'day',    left(coalesce(p_draft#>>'{prices,day}', ''), 60),
        'week',   left(coalesce(p_draft#>>'{prices,week}', ''), 60),
        'month',  left(coalesce(p_draft#>>'{prices,month}', ''), 60),
        'coffee', left(coalesce(p_draft#>>'{prices,coffee}', ''), 60)),
    'hours', coalesce(p_draft->'hours', '{}'::jsonb),
    'facts', coalesce(p_draft->'facts', '{}'::jsonb),
    'website', left(coalesce(p_draft->>'website', ''), 300),
    'instagram', left(coalesce(p_draft->>'instagram', ''), 300),
    'whatsapp', left(coalesce(p_draft->>'whatsapp', ''), 60),
    'enquiry_email', lower(left(coalesce(p_draft->>'enquiry_email', ''), 200)),
    'photos', coalesce(p_draft->'photos', '[]'::jsonb),
    'mention', case when p_draft ? 'mention' then jsonb_build_object(
        'kind',  left(coalesce(p_draft#>>'{mention,kind}', ''), 20),
        'title', left(coalesce(p_draft#>>'{mention,title}', ''), 90),
        'body',  left(coalesce(p_draft#>>'{mention,body}', ''), 300),
        'cta',   left(coalesce(p_draft#>>'{mention,cta}', ''), 40),
        'url',   left(coalesce(p_draft#>>'{mention,url}', ''), 300))
      else null end));

  select * into d from public.owner_drafts
   where venue_id = p_venue and status in ('draft', 'submitted')
   order by updated_at desc limit 1;

  if found then
    update public.owner_drafts
       set draft = clean,
           owner_email = em,
           status = case when p_submit then 'submitted' else 'draft' end,
           submitted_at = case when p_submit then now() else submitted_at end,
           updated_at = now()
     where id = d.id
     returning * into d;
  else
    insert into public.owner_drafts (venue_id, owner_email, draft, status, submitted_at)
    values (p_venue, em, clean,
            case when p_submit then 'submitted' else 'draft' end,
            case when p_submit then now() else null end)
    returning * into d;
  end if;

  if p_submit then
    perform public.notify_phone(
      'Owner changes to review',
      coalesce(v_name, 'A space') || ': the owner submitted changes to their '
        'page. Read them in Owner changes and put them on, or send them back.',
      'pencil');
  end if;

  return jsonb_build_object('id', d.id, 'status', d.status,
                            'submitted_at', d.submitted_at);
end $$;
grant execute on function public.owner_save_draft(uuid, jsonb, boolean) to authenticated;

-- ------------------------------------------------ a template for a space that has claimed
-- Until now "Reply" on a claimed space offered the "ready to claim"
-- email. A first draft: change it in Outreach, Templates.
insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('owner_account_how', 'Claimed: how to get into their Owner account',
 'Your Owner account for {space}',
 'Hi {first_name},

Thank you for claiming {space} on Nomadwise. Your page: {page_link}

Your Owner account is here: https://nomadmaps.io/owner

Sign in with the email you claimed with. There is no password: a sign-in link is sent to that address.

Under "My listing" you can correct the description, opening hours and facts, and add your own photos and prices. Press "Submit for review" when you are done. Every change is read by a person before it goes live.

If anything is unclear, just reply to this email.

{signoff}', 'outbound', 63)
on conflict (key) do nothing;

-- The visits already kept that came straight to the claim page within
-- three days after we wrote to the space: they followed our message
-- too.
update public.claim_visit_geo g
   set via = 'after'
 where g.via is null
   and g.venue_id is not null
   and exists (select 1 from public.space_contacts s
                where s.venue_id = g.venue_id and not s.is_test
                  and s.last_out_at < g.at
                  and s.last_out_at > g.at - interval '3 days')
   and not g.dc
   and exists (select 1 from public.app_events e
                where left(e.name, 6) = 'claim_'
                  and e.name = 'claim_opened'
                  and e.props ->> 'visit' = g.visit
                  and coalesce(e.props ->> 'from', '') in ('', '/')
                  and coalesce(e.props ->> 'referrer', '') = '');
