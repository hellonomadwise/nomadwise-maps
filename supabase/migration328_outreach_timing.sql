-- Migration 328: When we send (Claim plan).
--
-- Jonathan, 13 Nov 2026: "Also want to track the days I send outreach
-- and times, to over time work out when is the best to send outreach
-- or comms out."
--
-- Every "I sent it" already keeps its day and time (outreach_messages.at).
-- What was missing is a way to read it: each hello and each follow-up,
-- with the day of the week and the hour in the SPACE'S OWN local time
-- (an email sent at 10 in London lands at 5 in the afternoon in Bali),
-- and what came of it: claim page opened, claimed, replied.
--
-- The app does the counting, so that "Your send days" can be shown in
-- the reader's own time. Nothing is stored: this only reads.

-- The time zone a space lives in, from its country and where it is on
-- the map. Countries with one time are looked up (tz_countries, the
-- list the claim page already uses); the ones with several that we
-- have spaces in are told apart by longitude, roughly. Nothing known:
-- the zone the longitude falls in. No place at all: null.
create or replace function public.outreach_space_tz(
  p_country text, p_lat double precision, p_lng double precision)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  c   text := lower(btrim(coalesce(p_country, '')));
  lat double precision := p_lat;
  lng double precision := p_lng;
  v   text;
  h   integer;
begin
  v := case
    when c in ('england', 'scotland', 'wales', 'northern ireland', 'united kingdom',
               'uk', 'great britain') then 'Europe/London'
    when c = 'indonesia' then
      case when lng is null then 'Asia/Makassar'      -- most of ours are in Bali
           when lng < 114.45 then 'Asia/Jakarta'      -- Sumatra, Java
           when lng < 126.5 then 'Asia/Makassar'      -- Bali, Lombok, Sulawesi
           else 'Asia/Jayapura' end
    when c = 'spain' then case when lng < -12 then 'Atlantic/Canary' else 'Europe/Madrid' end
    when c = 'portugal' then case when lng < -20 then 'Atlantic/Azores' else 'Europe/Lisbon' end
    when c = 'germany' then 'Europe/Berlin'
    when c = 'vietnam' then 'Asia/Ho_Chi_Minh'
    when c = 'india' then 'Asia/Kolkata'
    when c = 'malaysia' then 'Asia/Kuala_Lumpur'
    when c in ('turkey', 'türkiye', 'turkiye') then 'Europe/Istanbul'
    when c = 'cyprus' then 'Asia/Nicosia'
    when c in ('cabo verde', 'cape verde') then 'Atlantic/Cape_Verde'
    when c in ('czech republic', 'czechia') then 'Europe/Prague'
    when c = 'china' then 'Asia/Shanghai'
    when c = 'new zealand' then 'Pacific/Auckland'
    when c = 'french polynesia' then 'Pacific/Tahiti'
    when c = 'ecuador' then case when lng < -85 then 'Pacific/Galapagos' else 'America/Guayaquil' end
    when c = 'chile' then case when lng < -100 then 'Pacific/Easter' else 'America/Santiago' end
    when c = 'mexico' then
      case when lng is null then 'America/Mexico_City'
           when lng > -89.0 then 'America/Cancun'
           when lng < -114.7 then 'America/Tijuana'
           when lng < -105.8 and lat > 22 then 'America/Mazatlan'
           else 'America/Mexico_City' end
    when c = 'brazil' then case when lng < -57 then 'America/Manaus' else 'America/Sao_Paulo' end
    when c in ('united states', 'usa', 'united states of america') then
      case when lng is null then 'America/New_York'
           when lng < -154 then 'Pacific/Honolulu'
           when lng < -130 then 'America/Anchorage'
           when lng < -114.0 then 'America/Los_Angeles'
           when lng < -109.05 and lat < 37 then 'America/Phoenix'
           when lng < -101.5 then 'America/Denver'
           when lng < -85.5 then 'America/Chicago'
           else 'America/New_York' end
    when c = 'canada' then
      case when lng is null then 'America/Toronto'
           when lng < -115 then 'America/Vancouver'
           when lng < -110 then 'America/Edmonton'
           when lng < -101.4 then 'America/Regina'
           when lng < -90 then 'America/Winnipeg'
           when lng < -68 then 'America/Toronto'
           when lng < -57.1 then 'America/Halifax'
           else 'America/St_Johns' end
    when c = 'australia' then
      case when lng is null then 'Australia/Sydney'
           when lng < 129 then 'Australia/Perth'
           when lng < 138 and lat > -26 then 'Australia/Darwin'
           when lng < 141 then 'Australia/Adelaide'
           when lat > -29 then 'Australia/Brisbane'
           when lat < -39.2 then 'Australia/Hobart'
           else 'Australia/Sydney' end
    else null end;

  -- Any other country: its own zone; with several, the one whose
  -- clock sits nearest to where the sun says the place is (most
  -- countries keep their clocks a little ahead of the sun).
  if v is null and c <> '' then
    begin
      select t.tz into v
        from public.tz_countries t
       where lower(public.claim_geo_country(t.iso)) = c
       order by case when lng is null then 0
                     else abs(extract(epoch from (now() at time zone t.tz)
                                               - (now() at time zone 'UTC')) / 3600.0
                              - (lng / 15.0 + 0.5)) end,
                t.tz
       limit 1;
    exception when others then
      v := null;
    end;
  end if;

  -- No country we know: the zone the longitude falls in. ("Etc/GMT-7"
  -- is seven hours AHEAD of London; the sign is the other way round.)
  if v is null and lng is not null and lng between -180 and 180 then
    h := round(lng / 15.0)::integer;
    v := 'Etc/GMT' || case when h > 0 then '-' || h when h < 0 then '+' || abs(h) else '' end;
  end if;

  -- Never hand back a name the database does not know.
  if v is not null then
    begin
      perform now() at time zone v;
    exception when others then
      v := null;
    end;
  end if;
  return v;
end $function$;

revoke all on function public.outreach_space_tz(text, double precision, double precision) from public, anon;
grant execute on function public.outreach_space_tz(text, double precision, double precision) to authenticated, service_role;

-- Every hello and every follow-up we sent to a space since 1 October
-- 2026, with the day and hour it landed there and what came of it.
--   kind     hello: a first-contact message (or the first thing we
--            ever wrote to a space that had not written to us);
--            nudge: "any questions?" after a claim page was opened, or
--            a follow-up. Answers to their messages are not counted.
--   ch       email, whatsapp, instagram, facebook, form
--   dow      1 Monday .. 7 Sunday, in the space's local time (null
--            when we do not know where the space is)
--   hour     0 .. 23, in the space's local time
--   opened   a person (not one of us, not a machine) opened the
--            space's claim page within 30 days after the message
--   claimed  the space claimed its page after the message
--   replied  they wrote to us within 45 days after the message
create or replace function public.admin_outreach_timing()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_since timestamptz := '2026-10-01 00:00:00+00';
  v_rows  jsonb;
begin
  if not public.is_admin() then raise exception 'Team only.'; end if;

  with m as (
    select o.id, o.contact_id, o.at, o.template_key, o.sent_by,
           c.venue_id, c.country as c_country, c.stage, c.stage_at,
           row_number() over (partition by o.contact_id order by o.at, o.id) as nth,
           exists (select 1 from public.outreach_messages i
                    where i.contact_id = o.contact_id and i.direction = 'in'
                      and i.at < o.at) as in_before
      from public.outreach_messages o
      join public.space_contacts c on c.id = o.contact_id
     where o.direction = 'out' and not coalesce(c.is_test, false)
       and o.send_error is null
  ), k as (
    select m.*,
           case when m.template_key like 'invite%' then 'hello'
                when m.template_key ~ '^(claim_looked|follow_up|followup)' then 'nudge'
                when m.template_key is null and m.nth = 1 and not m.in_before then 'hello'
                else null end as kind,
           -- (what "I sent it" wrote down comes first: the WhatsApp
           -- wording is also what goes out on Instagram)
           case when m.sent_by ilike '%(instagram)%' then 'instagram'
                when m.sent_by ilike '%(facebook)%' then 'facebook'
                when m.sent_by ilike '%form)%' then 'form'
                when m.template_key like '%\_wa' or m.sent_by ilike '%(whatsapp)%' then 'whatsapp'
                else 'email' end as ch
      from m
     where m.at >= v_since
  ), z as (
    select k.*, v.webflow_slug,
           public.outreach_space_tz(coalesce(nullif(btrim(v.country), ''), k.c_country),
                                    v.lat, v.lng) as tz
      from k
      left join public.venues v on v.id = k.venue_id
     where k.kind is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', z.at,
           'kind', z.kind,
           'ch', z.ch,
           'dow', case when z.tz is null then null
                       else extract(isodow from (z.at at time zone z.tz))::integer end,
           'hour', case when z.tz is null then null
                        else extract(hour from (z.at at time zone z.tz))::integer end,
           'opened', coalesce(z.webflow_slug, '') <> '' and exists (
               select 1 from public.app_events e
                where e.name = 'claim_opened'
                  and e.props ->> 'seed' = z.webflow_slug
                  and e.created_at > z.at
                  and e.created_at < z.at + interval '30 days'
                  and not exists (select 1 from public.team_devices t where t.anon_id = e.anon_id)
                  and not exists (select 1 from public.bot_visitors b where b.anon_id = e.anon_id)),
           'claimed', (z.stage in ('claimed', 'verified') and z.stage_at > z.at)
               or (z.venue_id is not null and exists (
                     select 1 from public.listing_claims q
                      where q.venue_id = z.venue_id
                        and q.status in ('free', 'paid', 'free_pending', 'awaiting_approval')
                        and q.created_at > z.at)),
           'replied', exists (
               select 1 from public.outreach_messages i
                where i.contact_id = z.contact_id and i.direction = 'in'
                  and i.at > z.at and i.at < z.at + interval '45 days')
         ) order by z.at), '[]'::jsonb)
    into v_rows
    from z;

  return jsonb_build_object('since', v_since, 'min_sample', 30, 'rows', v_rows);
end $function$;

revoke all on function public.admin_outreach_timing() from public, anon;
grant execute on function public.admin_outreach_timing() to authenticated, service_role;
