-- Migration 153: who looked at claiming, and the whole picture.
--
-- Jonathan, 7 Oct 2026, two things about Outreach.
--
-- 1. "When I get the notification to my phone of a listing that I can
--    see has opened the claim page, but I can see that they haven't
--    done anything... a bit like a checkout cart where they got to
--    that point, but they didn't do anything. And then I would like to
--    be able to reach out", by email or WhatsApp: "did you have any
--    questions?".
--    The claim page already records every visit (app_events, the
--    claim_* events; our own devices are left out). This reads them
--    per space: who opened the claim page in the last 60 days, how
--    often, how far they got, and from where, for spaces that are
--    still unclaimed and that we have not written to since. They are a
--    step on the path in Outreach ("Looked at the claim page"), a line
--    on the space's card, and a job in "Next up". A space gets its
--    line in Outreach the moment its claim page is opened.
--    Two templates are added: an email and a WhatsApp message. The
--    visitor is not known to be the owner, and the words say so.
--    Nothing is sent by itself.
--
-- 2. "I don't know what the 875 places with no address yet, and 87
--    ready to write to relate to. Is this out of how many total
--    spaces... I would like to see an overall top down reconciliation"
--    The path counts lines in Outreach (a space can have two). The new
--    admin_outreach_whole() counts places, each one once, top down:
--    every place we know of, the ones live on the site, and of those
--    the ones claimed, set up by us, written to, answered, with no
--    address, and so on, for all places, coworking spaces and cafes.

alter table public.space_contacts
  add column if not exists claim_look_done_at timestamptz;
  -- "Done for now" on a look at the claim page: the line leaves the
  -- step until the claim page is opened again.

-- The visits are read several times each time Outreach opens: these
-- two keep that quick as the events pile up.
create index if not exists idx_app_events_claim
  on public.app_events (created_at desc) where left(name, 6) = 'claim_';
create index if not exists idx_venues_lower_name
  on public.venues (lower(name));

-- ------------------------------------------------ who looked at claiming
-- One row per space whose claim page somebody other than us opened in
-- the last p_days and did not finish: when last, how many openings by
-- how many visitors, the furthest step reached (0 looked, 1 began
-- adding a space, 2 began their details, 3 reached the plan), the
-- seconds the longest visit lasted, and where the last visitor came
-- from.
create or replace function public.claim_lookers(p_days integer default 60)
returns table (
  venue_id  uuid,
  last_at   timestamptz,
  opens     integer,
  visitors  integer,
  furthest  integer,
  secs      integer,
  from_path text,
  referrer  text,
  device    text
) language sql stable security definer set search_path = public as $$
  with ev as (
    select e.anon_id, e.name, e.props, e.created_at,
           coalesce(nullif(e.props ->> 'visit', ''),
                    e.anon_id || to_char(e.created_at, 'YYYYMMDDHH24')) as visit
      from public.app_events e
     where left(e.name, 6) = 'claim_'
       and e.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 60), 365)))
       and not exists (select 1 from public.team_devices t where t.anon_id = e.anon_id)
  ),
  vis as (
    select min(ev.anon_id) as anon_id, ev.visit,
           min(ev.created_at) as at,
           max(ev.props ->> 'seed') filter (where ev.name = 'claim_opened') as seed,
           (array_agg(ev.props ->> 'space' order by ev.created_at desc)
              filter (where coalesce(ev.props ->> 'space', '') <> ''))[1] as space,
           max(ev.props ->> 'from') filter (where ev.name = 'claim_opened') as from_path,
           max(ev.props ->> 'referrer') filter (where ev.name = 'claim_opened') as referrer,
           max(ev.props ->> 'device') filter (where ev.name = 'claim_opened') as device,
           max(case when ev.name in ('claim_to_payment', 'claim_free') then 3
                    when ev.name = 'claim_step' and ev.props ->> 'to' = 'plan' then 3
                    when ev.name = 'claim_step' and ev.props ->> 'to' = 'about' then 2
                    when ev.name = 'claim_typed' then 2
                    when ev.name = 'claim_step' and ev.props ->> 'to' = 'add_space' then 1
                    -- the step every event says it happened on (a
                    -- form picked up again starts where it was left)
                    when ev.props ->> 'step' = 'plan' then 3
                    when ev.props ->> 'step' = 'about' then 2
                    when ev.props ->> 'step' = 'add_space' then 1
                    else 0 end) as furthest,
           max(case when (ev.props ->> 'secs') ~ '^[0-9]{1,6}$'
                    then (ev.props ->> 'secs')::integer else 0 end) as secs,
           bool_or(ev.name = 'claim_free') as done
      from ev
     group by ev.visit
  ),
  hit as (
    select vis.*, m.id as venue_id
      from vis
     cross join lateral (
            select v.id
              from public.venues v
             where (coalesce(vis.seed, '') <> '' and v.webflow_slug = vis.seed)
                or lower(v.name) = lower(coalesce(nullif(vis.space, ''), nullif(vis.seed, '')))
             order by (coalesce(vis.space, '') <> '' and lower(v.name) = lower(vis.space)) desc,
                      coalesce(v.webflow_slug = vis.seed, false) desc,
                      (v.webflow_cms_id is not null) desc, v.id
             limit 1) m
     where not vis.done
  )
  select h.venue_id, max(h.at), count(*)::integer, count(distinct h.anon_id)::integer,
         max(h.furthest)::integer, max(h.secs)::integer,
         (array_agg(h.from_path order by h.at desc))[1],
         (array_agg(h.referrer order by h.at desc))[1],
         (array_agg(h.device order by h.at desc))[1]
    from hit h
   group by h.venue_id;
$$;
revoke all on function public.claim_lookers(integer) from public, anon, authenticated;
grant execute on function public.claim_lookers(integer) to service_role;

-- The spaces with a look still to follow up, each with one of its
-- lines in Outreach: the space is unclaimed, a line of it has not
-- stepped off, and the claim page was opened after we last wrote to
-- the space and after any "Done for now".
create or replace function public.claim_look_lines()
returns table (
  contact_id uuid,
  venue_id   uuid,
  last_at    timestamptz,
  opens      integer,
  visitors   integer,
  furthest   integer,
  secs       integer,
  from_path  text,
  referrer   text,
  device     text,
  form_email text,   -- the address typed into a claim form left unfinished
  form_name  text
) language sql stable security definer set search_path = public as $$
  select c.id, l.venue_id, l.last_at, l.opens, l.visitors, l.furthest, l.secs,
         l.from_path, l.referrer, l.device, k.owner_email, k.owner_name
    from public.claim_lookers(60) l
    join public.venues v on v.id = l.venue_id
    -- one line per space: the one with an address, else the oldest
    join lateral (
           select s.id
             from public.space_contacts s
            where s.venue_id = l.venue_id and not s.is_test
              and s.stage in ('new', 'contacted', 'replied')
            order by (s.email is not null) desc, s.created_at, s.id
            limit 1) c on true
    left join lateral (
           select nullif(lower(btrim(q.owner_email)), '') as owner_email,
                  nullif(btrim(q.owner_name), '') as owner_name
             from public.listing_claims q
            where q.venue_id = l.venue_id and q.status in ('started', 'abandoned')
              and q.created_at > now() - interval '60 days'
            order by q.created_at desc
            limit 1) k on true
   where true
     -- a claim that went through, or waits for our decision, is not a
     -- look that came to nothing
     and not exists (select 1 from public.listing_claims q
                      where q.venue_id = l.venue_id
                        and q.status in ('free_pending', 'awaiting_approval', 'paid', 'free'))
     and btrim(coalesce(v.listing_owner_email, '')) = ''
     and coalesce(v.listing_tier, 'free') <> 'verified'
     -- nothing written to the space, on any of its lines, since the
     -- look, and no "Done for now" since
     and not exists (select 1 from public.space_contacts s
                      where s.venue_id = l.venue_id and not s.is_test
                        and (s.last_out_at >= l.last_at
                             or s.claim_look_done_at >= l.last_at));
$$;
revoke all on function public.claim_look_lines() from public, anon, authenticated;
grant execute on function public.claim_look_lines() to service_role;

-- ------------------------------------------------ a line for a space
-- The space's line in Outreach, made if it has none (as "Add listed
-- spaces" makes them, one at a time). Returns the line's id.
create or replace function public.outreach_line_for_venue(p_venue uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  cid uuid;
  v   public.venues%rowtype;
  em  text;
begin
  select c.id into cid from public.space_contacts c
   where c.venue_id = p_venue
   order by (c.email is not null) desc, c.created_at
   limit 1;
  if cid is not null then
    return cid;
  end if;
  select * into v from public.venues where id = p_venue;
  if not found then
    return null;
  end if;
  -- Only a space "Add listed spaces" would take: on the site, open,
  -- with no owner. (The claim page can be opened by anyone, under any
  -- name.)
  if v.webflow_cms_id is null
     or coalesce(v.website_status, '') = 'retired'
     or coalesce(v.business_status, '') = 'CLOSED_PERMANENTLY'
     or btrim(coalesce(v.listing_owner_email, '')) <> ''
     or coalesce(v.listing_tier, 'free') = 'verified' then
    return null;
  end if;
  -- two openings at the same moment make one line, not two
  perform pg_advisory_xact_lock(hashtext('outreach_line:' || p_venue::text));
  select c.id into cid from public.space_contacts c
   where c.venue_id = p_venue limit 1;
  if cid is not null then
    return cid;
  end if;
  select lower(btrim(x)) into em
    from unnest(coalesce(v.contact_emails, '{}')) x
   where position('@' in x) > 1
   limit 1;
  -- one contact per address: never an address another line holds
  if em is not null and exists (select 1 from public.space_contacts c
                                 where lower(c.email) = em) then
    em := null;
  end if;
  insert into public.space_contacts
    (venue_id, space_name, kind, city, country, email, website, instagram, source, stage)
  values
    (v.id, v.name, v.type, nullif(btrim(v.city), ''), nullif(btrim(v.country), ''),
     em, nullif(btrim(v.website), ''), nullif(btrim(v.instagram), ''), 'listing', 'new')
  returning id into cid;
  return cid;
end $$;
revoke all on function public.outreach_line_for_venue(uuid) from public, anon, authenticated;
grant execute on function public.outreach_line_for_venue(uuid) to service_role;

-- ------------------------------------------------ the ping when the claim page opens
-- As migration 75, and the space gets its line in Outreach.
create or replace function public.claim_opened(
  p_seed text, p_from text, p_referrer text, p_user_agent text)
returns void language plpgsql security definer set search_path = public as $$
declare
  seed   text := nullif(left(trim(coalesce(p_seed, '')), 200), '');
  frm    text := nullif(left(trim(coalesce(p_from, '')), 300), '');
  ref    text := nullif(left(trim(coalesce(p_referrer, '')), 300), '');
  ua     text := nullif(left(trim(coalesce(p_user_agent, '')), 300), '');
  v_id   uuid;
  v_name text;
  v_city text;
  what   text;
  whence text;
  recent int;
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
  what := case when v_name is not null
               then ' for ' || v_name || coalesce(' in ' || nullif(v_city, ''), '')
               when seed is not null then ' for "' || seed || '"'
               else '' end;
  whence := case when frm is not null then 'from nomadwise.io' || frm
                 when ref is not null then 'from ' ||
                      regexp_replace(ref, '^https?://(www\.)?', '')
                 else 'direct, no referrer' end;

  perform public.notify_phone(
    'Claim page opened',
    'Someone opened the claim page' || what || ', ' || whence || '.',
    'eyes');
end $$;
grant execute on function public.claim_opened(text, text, text, text) to anon, authenticated;

-- ------------------------------------------------ the list
-- As migration 150, with the look on each row and its own step.
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
      select * from public.claim_look_lines()
    )
    select jsonb_agg(row_to_json(x)::jsonb order by x.sort_first, x.sort_at desc)
      from (
        select c.id, c.venue_id, c.space_name, c.kind, c.city, c.country,
               c.person_name, c.email, c.phone, c.website, c.instagram,
               c.source, c.form_name, c.stage, c.stage_at, c.first_in_at,
               c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.unsubscribed_at, c.is_test,
               (c.email is null) as no_email,
               -- the look's own list: the latest look first, with or
               -- without an address
               (case when st = 'claim_looked' then false else c.email is null end) as sort_first,
               (case when st = 'claim_looked' then l.last_at
                     else greatest(coalesce(c.last_in_at, c.created_at), coalesce(c.last_out_at, c.created_at), c.stage_at) end) as sort_at,
               v.google_place_id as place_id,
               case when l.contact_id is not null then jsonb_build_object(
                 'last_at', l.last_at, 'opens', l.opens, 'visitors', l.visitors,
                 'furthest', l.furthest, 'secs', l.secs, 'from', l.from_path,
                 'referrer', l.referrer, 'device', l.device,
                 'form_email', l.form_email, 'form_name', l.form_name) end as claim_look,
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
                  when 'claimed'     then coalesce(a.mine, false)
                  when 'not_opened'  then coalesce(a.mine and not a.accessed, false)
                  when 'ours'        then coalesce(not a.mine, false)
                  when 'opened'      then coalesce(a.accessed, false)
                  when 'opened_only' then coalesce(a.accessed and a.did = 0, false)
                  when 'used'        then coalesce(a.did > 0, false)
                  when 'looked'      then coalesce(a.mine and a.looked, false)
                  when 'verified'    then coalesce(a.mine and a.tier = 'verified', false)
                  else false end)
         order by sort_first, sort_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer, text, text) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer, text, text) to authenticated;

-- ------------------------------------------------ the numbers for the picture
-- As migration 150, with the look as a step of "Reaching them".
create or replace function public.admin_outreach_path()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  reach  jsonb;
  own    jsonb;
  paying integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;

  select jsonb_build_object(
           'no_email',    count(*) filter (where c.stage = 'new' and c.email is null),
           'ready',       count(*) filter (where c.stage = 'new' and c.email is not null),
           'waiting',     count(*) filter (where c.stage = 'contacted'),
           'follow_up',   count(*) filter (where public.outreach_follow_up_due(
                                                   c.stage, c.follow_up_on, c.last_out_at)),
           'replied',     count(*) filter (where c.stage = 'replied'),
           'stepped_off', count(*) filter (where c.stage in
                                             ('not_now', 'declined', 'unsubscribed', 'bounced')))
    into reach
    from public.space_contacts c
   where not c.is_test;

  -- Spaces whose claim page was opened and that are still to follow
  -- up (migration 153). Counted by space.
  begin
    reach := reach || jsonb_build_object('claim_looked',
      (select count(distinct l.venue_id) from public.claim_look_lines() l));
  exception when others then
    null;
  end;

  -- "mine": they claimed it themselves, or have been in the Owner
  -- account. The rest we set up (Verified by us, or an owner put on by
  -- hand) and they have not claimed: "ours", the ones to invite.
  select jsonb_build_object(
           'claimed',     count(*) filter (where x.mine),
           'not_opened',  count(*) filter (where x.mine and not x.accessed),
           'opened',      count(*) filter (where x.accessed),
           'opened_only', count(*) filter (where x.accessed and x.did = 0),
           'used',        count(*) filter (where x.did > 0),
           'looked',      count(*) filter (where x.mine and x.looked),
           'verified',    count(*) filter (where x.mine and x.tier = 'verified'),
           'ours',        count(*) filter (where not x.mine),
           'ours_verified', count(*) filter (where not x.mine and x.tier = 'verified'))
    into own
    from (select y.*, (y.claimed_self or y.accessed) as mine
            from (select a.*,
                         (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
                         (a.signed_in_at is not null or a.opens > 0
                          or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
                    from public.outreach_owner_activity() a
                   where not a.test) y) x;

  -- Paying, as the Money card counts it.
  begin
    paying := (public.admin_money() ->> 'paying')::integer;
  exception when others then
    paying := null;
  end;

  return jsonb_build_object(
    'reach', reach,
    'owners', own,
    'paying', paying,
    -- lines marked as tests, left out of every number above
    'tests', (select count(*) from public.space_contacts c where c.is_test),
    'visits_since', (select s.value #>> '{}' from public.sync_settings s
                      where s.key = 'owner_visits_since'));
end $$;
revoke all on function public.admin_outreach_path() from public, anon;
grant execute on function public.admin_outreach_path() to authenticated;

-- ------------------------------------------------ Next up, and the number beside Outreach
-- As migration 149, with the latest look.
create or replace function public.admin_next_up()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  out   jsonb := '{}'::jsonb;
  part  jsonb;
  pages jsonb;
  cand  jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;

  -- Text upgrades waiting for a Go: how many, on how many pages, and
  -- the most promising page among them.
  begin
    select jsonb_build_object(
             'n', coalesce(sum(t.waiting), 0),
             'pages', count(*),
             'venue_id', (array_agg(t.id order by t.impact desc, t.name))[1],
             'name', (array_agg(t.name order by t.impact desc, t.name))[1],
             'waiting', (array_agg(t.waiting order by t.impact desc, t.name))[1])
      into part
      from (select v.id, v.name, count(*) as waiting,
                   public.upgrade_impact(v, 'description') as impact
              from public.page_upgrades u
              join public.venues v on v.id = u.venue_id
             where u.kind <> 'photos' and u.status in ('proposed', 'failed')
             group by v.id) t;
    out := out || jsonb_build_object('drafts', part);
  exception when others then
    null;
  end;

  -- Price changes waiting for a Go: the first space as Price check
  -- lists them (by name).
  begin
    select jsonb_build_object(
             'n', coalesce(sum(t.waiting), 0),
             'spaces', count(*),
             'venue_id', (array_agg(t.id order by t.name, t.id))[1],
             'name', (array_agg(t.name order by t.name, t.id))[1],
             'waiting', (array_agg(t.waiting order by t.name, t.id))[1])
      into part
      from (select v.id, v.name, count(*) as waiting
              from public.product_changes c
              join public.venues v on v.id = c.venue_id
             where c.status in ('proposed', 'failed')
             group by v.id) t;
    out := out || jsonb_build_object('prices', part);
  exception when others then
    null;
  end;

  -- Pages short of photos, as "Add photos" lists them, without the
  -- ones whose new photos are already on their way.
  begin
    select jsonb_build_object(
             'n', count(*),
             'venue_id', (array_agg(t.id order by t.impact desc, t.photos, t.name))[1],
             'name', (array_agg(t.name order by t.impact desc, t.photos, t.name))[1],
             'photos', (array_agg(t.photos order by t.impact desc, t.photos, t.name))[1])
      into part
      from (select v.id, v.name, (f.facts ->> 'photos')::int as photos,
                   public.upgrade_impact(v, 'photos') as impact
              from public.venues v
              join public.venue_page_facts f on f.venue_id = v.id
             where public.upgrade_page_is_live(v)
               and (f.facts ->> 'photos') is not null
               and (f.facts ->> 'photos')::int < 5
               and not public.upgrade_owner_photos(v)
               and not exists (select 1 from public.page_upgrades u
                                where u.venue_id = v.id and u.kind = 'photos'
                                  and u.status in ('proposed', 'approved',
                                                   'failed', 'undo_requested'))) t;
    out := out || jsonb_build_object('photos', part);
  exception when others then
    null;
  end;

  -- The first page of "Choose a page" not dealt with yet (migration
  -- 142), and how many such pages the list holds (it shows 300).
  begin
    pages := public.admin_upgrades_pages(null, null, 300);
    select jsonb_build_object(
             'n', count(*),
             'more', jsonb_array_length(pages) >= 300,
             'venue_id', (array_agg(x ->> 'venue_id' order by ord))[1],
             'name', (array_agg(x ->> 'name' order by ord))[1],
             'reason', (array_agg(x ->> 'reason' order by ord))[1])
      into part
      from jsonb_array_elements(pages) with ordinality t(x, ord)
     where (x ->> 'section')::int = 1;
    out := out || jsonb_build_object('page', part);
  exception when others then
    null;
  end;

  -- The best bet on the Candidates list, and how many wait.
  begin
    cand := public.admin_candidates(null, 1, 0, 'best');
    out := out || jsonb_build_object('candidate', jsonb_build_object(
      'n', coalesce((cand ->> 'total')::int, 0),
      'place', cand -> 'rows' -> 0 ->> 'google_place_id',
      'name', cand -> 'rows' -> 0 ->> 'name',
      'area', cand -> 'rows' -> 0 ->> 'area',
      'coworking', coalesce((cand -> 'rows' -> 0 ->> 'coworking')::boolean, false),
      'mentions', coalesce((cand -> 'rows' -> 0 ->> 'mentions')::int, 0),
      'searches', (cand -> 'rows' -> 0 ->> 'searches')::int));
  exception when others then
    null;
  end;

  -- A space whose claim page was opened in the last two weeks and
  -- that is still to follow up (migration 153): how many, and the
  -- latest one.
  begin
    select jsonb_build_object(
             'n', count(*),
             'name', (array_agg(t.name order by t.last_at desc))[1],
             'at', max(t.last_at),
             'opens', (array_agg(t.opens order by t.last_at desc))[1])
      into part
      from (select l.venue_id, max(v.name) as name, max(l.last_at) as last_at,
                   max(l.opens) as opens
              from public.claim_look_lines() l
              join public.venues v on v.id = l.venue_id
             where l.last_at > now() - interval '14 days'
             group by l.venue_id) t;
    out := out || jsonb_build_object('claim_look', part);
  exception when others then
    null;
  end;

  -- The numbers beside the menu's other tools (migration 146): what
  -- is open in each. Each in its own block: a tool whose tables are
  -- not there says nothing, the others still do.
  declare
    n_outreach integer;
    n_review   integer;
    n_feedback integer;
  begin
    begin
      -- Outreach: a space answered and waits for a reply, or a
      -- follow-up you set has come due and nothing has been sent
      -- since that day (the date stays on the contact after sending).
      select count(*) into n_outreach
        from public.space_contacts c
       where not c.is_test
         and (c.stage = 'replied'
          or (c.follow_up_on is not null and c.follow_up_on <= current_date
              and (c.last_out_at is null
                   or c.last_out_at::date < c.follow_up_on)
              and c.stage not in ('claimed', 'verified', 'declined',
                                  'unsubscribed', 'bounced')));
      -- and the spaces that looked at claiming in the last two weeks
      n_outreach := n_outreach + coalesce((out -> 'claim_look' ->> 'n')::integer, 0);
    exception when others then
      n_outreach := null;
    end;
    begin
      -- Review submissions: reports waiting to be checked, and photos
      -- waiting for a yes or no.
      select count(*) filter (where s.status = 'pending')
           + count(*) filter (where s.photo_path is not null
                                and s.photo_status = 'pending')
        into n_review
        from public.submissions s;
    exception when others then
      n_review := null;
    end;
    begin
      -- Feedback inbox: messages not marked done.
      select count(*) into n_feedback
        from public.feedback f where f.status = 'new';
    exception when others then
      n_feedback := null;
    end;
    out := out || jsonb_build_object('menu', jsonb_strip_nulls(jsonb_build_object(
      'outreach', n_outreach, 'review', n_review, 'feedback', n_feedback)));
  end;

  return out;
end $$;
revoke all on function public.admin_next_up() from public, anon;
grant execute on function public.admin_next_up() to authenticated;

-- ------------------------------------------------ "Done for now" on a look
-- Every line of the space leaves the step until its claim page is
-- opened again.
create or replace function public.admin_outreach_look_done(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  vid uuid;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select c.venue_id into vid from public.space_contacts c where c.id = p_id;
  update public.space_contacts c
     set claim_look_done_at = now()
   where c.id = p_id or (vid is not null and c.venue_id = vid);
end $$;
revoke all on function public.admin_outreach_look_done(uuid) from public, anon;
grant execute on function public.admin_outreach_look_done(uuid) to authenticated;

-- ------------------------------------------------ a WhatsApp message we sent
-- Nothing is sent from here: this is the record of a message sent by
-- hand from WhatsApp, and the stage moving on (as for an email sent
-- from our own inbox, migration 122). Never to someone who asked us
-- not to write again.
create or replace function public.admin_outreach_log_whatsapp(p_id uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c   public.space_contacts%rowtype;
  who text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id for update;
  if not found then raise exception 'Contact not found.'; end if;
  if c.unsubscribed_at is not null then
    raise exception 'They asked us not to write again.';
  end if;
  who := coalesce((select email from auth.users where id = auth.uid()), 'founder');
  insert into public.outreach_messages (contact_id, direction, template_key, subject, body, sent_by)
  values (c.id, 'out', 'claim_looked_wa', 'WhatsApp', left(coalesce(p_body, ''), 4000),
          who || ' (WhatsApp)');
  update public.space_contacts
     set last_out_at = now(),
         stage = case when stage in ('new', 'contacted', 'not_now', 'replied') then 'contacted' else stage end
   where id = c.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_outreach_log_whatsapp(uuid, text) from public, anon;
grant execute on function public.admin_outreach_log_whatsapp(uuid, text) to authenticated;

-- ------------------------------------------------ the two templates
-- The visitor is not known to be the owner, so the words do not say
-- "you". (Rules as for every template: no em dashes, no promise of a
-- time, "Owner account".) A first draft: change them in Outreach,
-- Templates.
insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('claim_looked', 'Follow-up: someone looked at the claim page',
 'Any questions about claiming {space}?',
 'Hi {first_name},

Someone opened the claim page for {space} on Nomadwise recently. If that was you, or someone on your team, I wanted to ask whether anything was unclear, or whether you had a question before going ahead.

{space} is already on nomadwise.io: {page_link}

Claiming the page is free. You get an Owner account where you can correct the facts and add your own photos, description and prices. The claim page is here: {claim_link}

If it was not you, no problem, and nothing changes on your page.

{signoff}', 'outbound', 60),

('claim_looked_wa', 'WhatsApp: someone looked at the claim page',
 'WhatsApp',
 'Hi, this is Jonathan from Nomadwise. Someone opened the claim page for {space} on our site recently. If that was you, did you have any questions? Claiming the page is free: {claim_link}', 'outbound', 61)
on conflict (key) do nothing;

-- ------------------------------------------------ the whole picture
-- Every place we know of, each counted once, top down, for all
-- places ("all"), coworking spaces ("cw") and the rest ("cafe"):
--   found_unchecked  found by the nightly search, reviews not read
--   candidates       waiting for a yes or no
--   queue            said yes to, page not live yet
--   map_only         on the map, no page (not asked for, or removed)
--   retired          page taken down
--   live_closed      live page, Google says closed for good
--   tests            live, the owner is one of us
--   claimed          live, claimed by its owner
--   ours             live, set up by us, not claimed
--   u_replied ... u_none   live, open, unclaimed, by how far Outreach
--                    has got with the space: they replied, we wrote and
--                    wait, they stepped off, we hold an address and
--                    have not written, we hold no address, or the
--                    space has no line in Outreach at all
--   off_wrote, off_prospect   lines in Outreach not matched to a
--                    place of ours: they wrote to us, or we found them
--   look             of all those, the spaces whose claim page was
--                    opened and that are still to follow up
create or replace function public.admin_outreach_whole()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  o    jsonb := '{}'::jsonb;
  cand jsonb;
  r    record;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;

  for r in
    with act as materialized (
      select a.venue_id, a.test,
             (a.claimed_self or a.signed_in_at is not null or a.opens > 0
              or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as mine
        from public.outreach_owner_activity() a
    ),
    line as materialized (
      -- how far Outreach has got with each space: its furthest line
      select c.venue_id,
             max(case when c.stage = 'replied' then 5
                      when c.stage = 'contacted' then 4
                      when c.stage in ('not_now', 'declined', 'unsubscribed', 'bounced') then 3
                      when c.stage = 'new' and c.email is not null then 2
                      when c.stage = 'new' then 1
                      else 0 end) as best
        from public.space_contacts c
       where c.venue_id is not null and not c.is_test
       group by c.venue_id
    ),
    v as (
      select case when x.type = 'coworking' then 'cw' else 'cafe' end as t,
             case
               when coalesce(x.website_status, '') = 'retired' then 'retired'
               when x.website_status = 'released' then
                 case
                   when coalesce(x.business_status, '') = 'CLOSED_PERMANENTLY' then 'live_closed'
                   when coalesce(a.test, false) then 'tests'
                   when a.venue_id is not null and a.mine then 'claimed'
                   when a.venue_id is not null then 'ours'
                   when l.best = 5 then 'u_replied'
                   when l.best = 4 then 'u_waiting'
                   when l.best = 3 then 'u_stepped'
                   when l.best = 2 then 'u_ready'
                   when l.best = 1 then 'u_no_email'
                   else 'u_none' end
               when x.website_status in ('queued', 'published_hidden') then 'queue'
               else 'map_only' end as k
        from public.venues x
        left join act a on a.venue_id = x.id
        left join line l on l.venue_id = x.id
    )
    select v.k, count(*) as n_all,
           count(*) filter (where v.t = 'cw') as n_cw,
           count(*) filter (where v.t = 'cafe') as n_cafe
      from v
     group by v.k
  loop
    o := o || jsonb_build_object(r.k,
      jsonb_build_object('all', r.n_all, 'cw', r.n_cw, 'cafe', r.n_cafe));
  end loop;

  -- Lines in Outreach that are not yet a place of ours (nobody has
  -- matched them to one): counted apart, so no place is counted twice.
  for r in
    select case public.outreach_group(c.source)
             when 'prospect' then 'off_prospect' else 'off_wrote' end as k,
           count(*) as n_all,
           count(*) filter (where c.kind = 'coworking') as n_cw,
           count(*) filter (where c.kind is distinct from 'coworking') as n_cafe
      from public.space_contacts c
     where not c.is_test
       and c.venue_id is null
       and c.stage not in ('claimed', 'verified')
     group by 1
  loop
    o := o || jsonb_build_object(r.k,
      jsonb_build_object('all', r.n_all, 'cw', r.n_cw, 'cafe', r.n_cafe));
  end loop;

  -- Candidates: the list's own numbers (not split by kind).
  begin
    cand := public.admin_candidates(null, 1, 0, 'best');
    o := o || jsonb_build_object(
      'candidates', jsonb_build_object('all', coalesce((cand ->> 'total')::integer, 0)),
      'found_unchecked', jsonb_build_object('all', coalesce((cand ->> 'waiting_scan')::integer, 0)));
  exception when others then
    null;
  end;

  -- The claim page opened, still to follow up.
  begin
    select o || jsonb_build_object('look', jsonb_build_object(
             'all', count(distinct l.venue_id),
             'cw', count(distinct l.venue_id) filter (where x.type = 'coworking'),
             'cafe', count(distinct l.venue_id) filter (where x.type is distinct from 'coworking')))
      into o
      from public.claim_look_lines() l
      join public.venues x on x.id = l.venue_id;
  exception when others then
    null;
  end;

  return o;
end $$;
revoke all on function public.admin_outreach_whole() from public, anon;
grant execute on function public.admin_outreach_whole() to authenticated;

-- ------------------------------------------------ lines for the looks
-- The ping makes a space's line when its claim page is opened by its
-- link. A visitor who opens the bare claim page and picks the space
-- there is seen in the events only, so this catches those up: now,
-- and every half hour.
create or replace function public.claim_look_sync()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r record;
  n integer := 0;
begin
  for r in select l.venue_id from public.claim_lookers(60) l
            where not exists (select 1 from public.space_contacts c
                               where c.venue_id = l.venue_id) loop
    begin
      if public.outreach_line_for_venue(r.venue_id) is not null then
        n := n + 1;
      end if;
    exception when others then
      null;
    end;
  end loop;
  return n;
end $$;
revoke all on function public.claim_look_sync() from public, anon, authenticated;
grant execute on function public.claim_look_sync() to service_role;

do $$
begin
  perform public.claim_look_sync();
exception when others then
  raise warning 'claim_look_sync: %', sqlerrm;
end $$;

do $$
begin
  perform cron.unschedule('claim-look-sync');
exception when others then null;
end $$;
select cron.schedule('claim-look-sync', '7,37 * * * *',
  'select public.claim_look_sync()');
