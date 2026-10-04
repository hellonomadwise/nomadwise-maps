-- ============================================================
-- Migration 125: Page upgrades, a queue of improvements to listing
-- pages that a founder approves one by one.
-- (Applied automatically by the build; nothing to paste.)
--
-- Why: most listing pages are thin. On 4 Oct 2026, 246 of the 338
-- coworking pages had no description and 1,008 of 1,011 pages shared
-- one generic search description. A better page is worth more to the
-- nomad and to the space we ask to claim it. Jonathan wants the
-- changes lined up by likely impact, to see before and after, and to
-- press Go himself. Nothing reaches the website without that.
--
-- How it works:
--   page_upgrades     one proposed change to one page: the kind, the
--                     text on the page now, the proposed text, where
--                     it came from, an impact score and its status
--                     (proposed, approved, applied, skipped, failed,
--                     undo_requested, undone).
--   upgrade_requests  "prepare more of these", filed from the control
--                     centre. Rule-built kinds are prepared at once;
--                     written kinds wait to be drafted and uploaded.
--   page_popularity   page views per listing page, loaded from the
--                     site's analytics, so the queue can be ordered.
--   venue_page_facts  what the nightly sync saw on each page (search
--                     description, words of description, WiFi, prices,
--                     area and region), so gaps can be counted here.
--                     Its own table, so the map's read of venues does
--                     not carry it.
--
-- Kinds in this version:
--   search_description  the line Google shows under the title. Built
--                       here from the facts we hold. Goes into the
--                       page's Meta Description.
--   description         the text of the page. Drafted outside the app
--                       and loaded with import_page_upgrades(). Goes
--                       into More Info, keeping any price lines.
-- A founder's Go sets the row to approved; the ten-minute website push
-- writes it to Webflow, publishes the page and marks it applied, with
-- the text it replaced kept for Undo.
-- ============================================================

create table if not exists public.venue_page_facts (
  venue_id    uuid primary key references public.venues(id) on delete cascade,
  facts       jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

create table if not exists public.page_popularity (
  slug         text primary key,
  views        integer not null default 0,
  visitors     integer not null default 0,
  days         integer not null default 90,
  measured_at  timestamptz not null default now()
);

create table if not exists public.page_upgrades (
  id              uuid primary key default gen_random_uuid(),
  venue_id        uuid not null references public.venues(id) on delete cascade,
  kind            text not null check (kind in ('search_description', 'description')),
  status          text not null default 'proposed'
                  check (status in ('proposed', 'approved', 'applied', 'skipped',
                                    'failed', 'undo_requested', 'undone')),
  before_text     text,
  proposed_text   text not null check (char_length(proposed_text) <= 8000),
  final_text      text check (char_length(final_text) <= 8000),
  previous_value  text,
  source          text not null default 'rule' check (source in ('rule', 'drafted')),
  batch           text,
  note            text check (char_length(note) <= 1000),
  impact          numeric not null default 0,
  error           text,
  created_at      timestamptz not null default now(),
  decided_at      timestamptz,
  decided_by      text,
  applied_at      timestamptz,
  -- Set by the push just before it writes, so a founder cannot take
  -- a change back while it is going onto the page.
  writing_since   timestamptz
);
create index if not exists idx_page_upgrades_status
  on public.page_upgrades(status, impact desc);
create index if not exists idx_page_upgrades_venue
  on public.page_upgrades(venue_id, kind);
-- One live proposal per page and kind. Skipped and undone rows stay
-- as history and do not block a new one.
create unique index if not exists idx_page_upgrades_one_open
  on public.page_upgrades(venue_id, kind)
  where status in ('proposed', 'approved', 'applied', 'failed', 'undo_requested');

create table if not exists public.upgrade_requests (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('search_description', 'description',
                                            'prices', 'wifi', 'other')),
  how_many    integer not null default 20 check (how_many between 1 and 200),
  note        text check (char_length(note) <= 1000),
  status      text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  asked_by    text,
  created_at  timestamptz not null default now(),
  done_at     timestamptz
);

alter table public.venue_page_facts enable row level security;
drop policy if exists "venue_page_facts admin" on public.venue_page_facts;
create policy "venue_page_facts admin" on public.venue_page_facts
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
alter table public.page_popularity enable row level security;
alter table public.page_upgrades enable row level security;
alter table public.upgrade_requests enable row level security;
drop policy if exists "page_popularity admin" on public.page_popularity;
create policy "page_popularity admin" on public.page_popularity
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "page_upgrades admin" on public.page_upgrades;
create policy "page_upgrades admin" on public.page_upgrades
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "upgrade_requests admin" on public.upgrade_requests;
create policy "upgrade_requests admin" on public.upgrade_requests
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------ helpers

-- The line every page was created with (scripts/webflow_sync.py,
-- DESCRIPTION), followed by the space's name.
create or replace function public.upgrade_generic_line()
returns text language sql immutable as $$
  select 'Find cafes & coworking spaces for digital nomads with fast WiFi, '
         'affordable coffee, aircon, comfy seating, plugs, and quiet spots. | '::text
$$;

-- What the sync last saw on a venue's page; null when it has not
-- been read yet.
create or replace function public.upgrade_facts(p_venue uuid)
returns jsonb language sql stable set search_path = public as $$
  select f.facts from public.venue_page_facts f where f.venue_id = p_venue
$$;

-- The search description on the page now, as far as we know it.
create or replace function public.upgrade_current_meta(v public.venues)
returns text language sql stable set search_path = public as $$
  select case
    when x.f is null then null
    when coalesce(x.f ->> 'meta', '') <> '' then x.f ->> 'meta'
    when coalesce((x.f ->> 'meta_generic')::boolean, false)
      then public.upgrade_generic_line() || coalesce(v.name, '')
    else ''
  end
  from (select public.upgrade_facts(v.id) as f) x
$$;

-- True when the page still has the generic line, or nothing at all.
create or replace function public.upgrade_meta_is_generic(v public.venues)
returns boolean language sql stable set search_path = public as $$
  select x.f is not null
     and (coalesce((x.f ->> 'meta_generic')::boolean, false)
          or coalesce(x.f ->> 'meta', '') = ''
          or (x.f ->> 'meta') ilike 'Find cafes & coworking spaces for digital nomads%')
  from (select public.upgrade_facts(v.id) as f) x
$$;

-- A page that is live on the site.
create or replace function public.upgrade_page_is_live(v public.venues)
returns boolean language sql stable as $$
  select v.webflow_cms_id is not null
     and coalesce(v.website_status, '') = 'released'
     and coalesce(v.webflow_slug, '') <> ''
$$;

-- How much a change to this page is likely to matter, 0 to about 80.
-- Page views count most, then how well known the place is on Google;
-- a coworking space counts a quarter more than a cafe, and a missing
-- description more than a search description.
create or replace function public.upgrade_impact(v public.venues, p_kind text)
returns numeric language plpgsql stable set search_path = public as $$
declare
  vw integer := 0;
  s  numeric;
begin
  select coalesce(p.views, 0) into vw from public.page_popularity p where p.slug = v.webflow_slug;
  s := 10 * ln(1 + coalesce(vw, 0))
     + 2 * ln(1 + greatest(coalesce(v.google_reviews_snapshot, 0), 0));
  if v.type = 'coworking' then s := s * 1.25; end if;
  if p_kind = 'search_description' then s := s * 0.8; end if;
  return round(s, 1);
end $$;

-- Why this page is where it is in the queue, in plain words.
create or replace function public.upgrade_reason(v public.venues, p_kind text)
returns text language plpgsql stable set search_path = public as $$
declare
  vw   integer;
  days integer;
  out  text;
begin
  select p.views, p.days into vw, days from public.page_popularity p where p.slug = v.webflow_slug;
  if coalesce(vw, 0) > 0 then
    out := trim(to_char(vw, 'FM999,999,999')) || case when vw = 1 then ' page view' else ' page views' end
           || ' in ' || coalesce(days, 90) || ' days';
  else
    out := 'No page views recorded';
  end if;
  out := out || ' · ' || case when v.type = 'coworking' then 'coworking space' else 'cafe' end;
  if coalesce(v.google_reviews_snapshot, 0) > 0 then
    out := out || ' · ' || trim(to_char(v.google_reviews_snapshot, 'FM999,999,999')) || ' Google reviews';
  end if;
  return out;
end $$;

-- A list of things as words: "a", "a and b", "a, b and c".
create or replace function public.upgrade_and_list(p text[])
returns text language sql immutable as $$
  select case coalesce(array_length(p, 1), 0)
    when 0 then ''
    when 1 then p[1]
    else array_to_string(p[1:array_length(p, 1) - 1], ', ') || ' and ' || p[array_length(p, 1)]
  end
$$;

-- The search description built from what we hold: what and where,
-- then what a nomad would want to know, then the Google rating. Whole
-- sentences only, and never past 158 characters unless the first
-- sentence alone is longer.
create or replace function public.upgrade_search_description(v public.venues)
returns text language plpgsql stable set search_path = public as $$
declare
  f        jsonb := coalesce(public.upgrade_facts(v.id), '{}'::jsonb);
  area     text := nullif(trim(coalesce(f ->> 'area', v.neighbourhood, '')), '');
  region   text := nullif(trim(coalesce(f ->> 'region', '')), '');
  city     text := nullif(trim(coalesce(v.city, '')), '');
  country  text := nullif(trim(coalesce(v.country, '')), '');
  place    text;
  kind     text := case
                -- No "Yellow Coworking Space is a coworking space".
                when v.type = 'coworking' and v.name ~* 'co-?work' then 'a place to work'
                when v.type = 'coworking' then 'a coworking space'
                when v.name ~* '(caf[eé]|coffee|kaffee|kopi|co-?work)' then 'a place to work from'
                else 'a cafe to work from' end;
  feats    text[] := '{}';
  wifi     numeric := coalesce(v.wifi_speed_mbps, nullif(f ->> 'wifi', '')::numeric);
  parts    text[] := '{}';
  out      text;
  s        text;
begin
  -- Where. "in Victoria, London", "in Funchal, Madeira", "in Tallinn, Estonia".
  -- An area written "Kuta (Bali)" loses the bracket when the region says it.
  if area is not null and region is not null
     and lower(area) like '% (' || lower(region) || ')' then
    area := trim(left(area, char_length(area) - char_length(region) - 3));
  end if;
  if area is not null and region is not null and lower(area) <> lower(region) then
    place := area || ', ' || region;
  elsif coalesce(region, area, city) is not null then
    place := coalesce(region, area, city);
    if country is not null and lower(country) <> lower(place) then
      place := place || ', ' || country;
    end if;
  else
    place := country;
  end if;
  out := trim(coalesce(v.name, '')) || ' is ' || kind
         || case when place is not null then ' in ' || place else '' end || '.';

  -- What it has, most useful first, four at most.
  if wifi is not null and wifi > 0 then
    feats := feats || ('WiFi at ' || round(wifi)::text || ' Mbps');
  end if;
  if v.type = 'coworking' then
    if v.access_24h then feats := feats || '24 hour access'::text; end if;
    if v.call_room then feats := feats || 'call rooms'::text; end if;
    if v.monitor then feats := feats || 'monitors'::text; end if;
    if v.office_chairs then feats := feats || 'office chairs'::text; end if;
    if v.aircon then feats := feats || 'aircon'::text; end if;
    if v.power_outlets then feats := feats || 'plenty of plug sockets'::text; end if;
  else
    if v.power_outlets then feats := feats || 'plenty of plug sockets'::text; end if;
    if v.aircon then feats := feats || 'aircon'::text; end if;
    if v.quiet_space then feats := feats || 'a quiet space'::text; end if;
    if v.comfortable_seating then feats := feats || 'comfortable seating'::text; end if;
    if v.good_for_calls then feats := feats || 'room for calls'::text; end if;
  end if;
  if coalesce(array_length(feats, 1), 0) > 4 then
    feats := feats[1:4];
  end if;
  if coalesce(array_length(feats, 1), 0) > 0 then
    s := public.upgrade_and_list(feats) || '.';
    parts := parts || (upper(left(s, 1)) || substr(s, 2));
  end if;
  if coalesce(v.google_rating_snapshot, 0) >= 4
     and coalesce(v.google_reviews_snapshot, 0) >= 10 then
    parts := parts || ('Rated ' || to_char(v.google_rating_snapshot, 'FM0.0') || ' on Google.');
  end if;
  parts := parts || 'See photos, opening hours and how to get there.'::text;

  foreach s in array parts loop
    if char_length(out) + 1 + char_length(s) <= 158 then
      out := out || ' ' || s;
    end if;
  end loop;
  -- A name or an area written with a long dash gets a plain hyphen.
  return regexp_replace(out, '\s*[—–]\s*', ' - ', 'g');
end $$;

-- What may not go on a page. Returns '' when the text is fine.
create or replace function public.upgrade_text_problem(p_kind text, p_text text)
returns text language plpgsql immutable as $$
declare
  t text := coalesce(p_text, '');
begin
  if trim(t) = '' then
    return 'There is no text to put on the page.';
  end if;
  if t ~ '[—–]' then
    return 'Please take out the long dash; the site does not use them.';
  end if;
  if p_kind = 'search_description' then
    if t ~ E'[\\n\\r]' then
      return 'A search description is a single line.';
    end if;
    if char_length(trim(t)) < 50 then
      return 'That is too short to be useful in Google; aim for 120 to 160 characters.';
    end if;
    if char_length(trim(t)) > 300 then
      return 'That is too long; Google shows about 160 characters.';
    end if;
  elsif p_kind = 'description' then
    if char_length(trim(t)) < 150 then
      return 'That is too short for a page description.';
    end if;
    if char_length(t) > 6000 then
      return 'That is too long for a page description.';
    end if;
    if t ~ '<[a-zA-Z/]' then
      return 'Plain text only. Start a line with "## " for a heading.';
    end if;
  end if;
  return '';
end $$;

-- Ask GitHub to run the website push now. Not throttled: an approval
-- should not wait for the schedule (which in practice fires every few
-- hours), and GitHub keeps at most one run waiting behind the one in
-- progress. Best effort; the push also calls it when a run filled up.
create or replace function public.upgrades_nudge()
returns void language plpgsql security definer set search_path = public as $$
declare
  tok text;
begin
  select decrypted_secret into tok
    from vault.decrypted_secrets where name = 'github_actions_token' limit 1;
  if tok is null or tok = '' then
    return;
  end if;
  perform net.http_post(
    url := 'https://api.github.com/repos/hellonomadwise/nomadwise-maps'
           '/actions/workflows/webflow_push.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || tok,
      'Accept', 'application/vnd.github+json',
      'Content-Type', 'application/json',
      'User-Agent', 'nomadmaps-db',
      'X-GitHub-Api-Version', '2022-11-28'));
  update public.sync_nudges set last_at = now() where id = 1;
exception when others then
  return;
end $$;
revoke all on function public.upgrades_nudge() from public, anon, authenticated;
grant execute on function public.upgrades_nudge() to service_role;

create or replace function public.upgrades_admin_email()
returns text language sql stable as $$
  select lower(nullif(trim(coalesce(auth.jwt() ->> 'email', '')), ''))
$$;

-- ------------------------------------------------------- control centre

-- The numbers at the top of the Page upgrades screen, the gaps by
-- kind and the open requests.
create or replace function public.admin_upgrades_overview()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select jsonb_build_object(
    'counts', (select coalesce(jsonb_object_agg(s.status, s.n), '{}'::jsonb)
                 from (select status, count(*) n from public.page_upgrades group by status) s),
    'pages', (select count(*) from public.venues v where public.upgrade_page_is_live(v)),
    'facts_pages', (select count(*) from public.venues v
                     where public.upgrade_page_is_live(v)
                       and public.upgrade_facts(v.id) is not null),
    'facts_at', (select max(f.updated_at) from public.venue_page_facts f),
    'popularity_at', (select max(p.measured_at) from public.page_popularity p),
    'popularity_days', (select max(p.days) from public.page_popularity p),
    'kinds', jsonb_build_array(
      jsonb_build_object(
        'kind', 'search_description',
        'title', 'Search descriptions',
        'what', 'The line Google shows under the page title. Built from the facts we hold, so more can be prepared straight away.',
        'instant', true,
        'gap', (select count(*) from public.venues v
                 where public.upgrade_page_is_live(v) and public.upgrade_meta_is_generic(v)
                   and not exists (select 1 from public.page_upgrades u
                                    where u.venue_id = v.id and u.kind = 'search_description')),
        'gap_words', 'pages still on the generic line',
        'waiting', (select count(*) from public.page_upgrades u
                     where u.kind = 'search_description' and u.status = 'proposed')),
      jsonb_build_object(
        'kind', 'description',
        'title', 'Page descriptions',
        'what', 'The text of the page. Each one is written from the space''s own website, so a batch is drafted, uploaded and then waits here for your Go.',
        'instant', false,
        'gap', (select count(*) from public.venues v
                 where public.upgrade_page_is_live(v) and v.type = 'coworking'
                   and public.upgrade_facts(v.id) is not null
                   and coalesce((public.upgrade_facts(v.id) ->> 'desc_words')::int, 0) = 0
                   and v.listing_owner_email is null
                   and not exists (select 1 from public.page_upgrades u
                                    where u.venue_id = v.id and u.kind = 'description'
                                      and u.status in ('proposed', 'approved', 'applied', 'failed',
                                                       'undo_requested'))),
        'gap_words', 'coworking pages with no description',
        'gap_more', (select count(*) from public.venues v
                      where public.upgrade_page_is_live(v) and v.type <> 'coworking'
                        and public.upgrade_facts(v.id) is not null
                        and coalesce((public.upgrade_facts(v.id) ->> 'desc_words')::int, 0) = 0
                        and v.listing_owner_email is null),
        'gap_more_words', 'cafe pages with no description',
        'waiting', (select count(*) from public.page_upgrades u
                     where u.kind = 'description' and u.status = 'proposed')),
      jsonb_build_object(
        'kind', 'prices',
        'title', 'Prices',
        'what', 'Day pass and membership prices on coworking pages. They have to be looked up on each space''s website, so this is a request too.',
        'instant', false,
        'gap', (select count(*) from public.venues v
                 where public.upgrade_page_is_live(v) and v.type = 'coworking'
                   and public.upgrade_facts(v.id) is not null
                   and not coalesce((public.upgrade_facts(v.id) ->> 'prices')::boolean, false)),
        'gap_words', 'coworking pages with no prices',
        'waiting', 0),
      jsonb_build_object(
        'kind', 'wifi',
        'title', 'WiFi speed',
        'what', 'A measured speed on the page. It comes from a nomad testing it in the app or from the owner, so it cannot be drafted; the count is here so you can see it.',
        'instant', false,
        'gap', (select count(*) from public.venues v
                 where public.upgrade_page_is_live(v) and v.type = 'coworking'
                   and coalesce(v.wifi_speed_mbps, 0) <= 0
                   and coalesce(nullif(public.upgrade_facts(v.id) ->> 'wifi', '')::numeric, 0) <= 0),
        'gap_words', 'coworking pages with no WiFi speed',
        'waiting', 0)),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', r.id, 'kind', r.kind, 'how_many', r.how_many, 'note', r.note,
                    'asked_by', r.asked_by, 'created_at', r.created_at)
                    order by r.created_at), '[]'::jsonb)
                   from public.upgrade_requests r where r.status = 'open')
  ) into out;
  return out;
end $$;
revoke all on function public.admin_upgrades_overview() from public, anon;
grant execute on function public.admin_upgrades_overview() to authenticated;

-- The queue. p_status: proposed, approved (also covers undo on its
-- way), applied, skipped (also undone), failed. Highest impact first.
create or replace function public.admin_upgrades_list(
  p_status text default 'proposed', p_kind text default null,
  p_q text default null, p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q   text := nullif(trim(coalesce(p_q, '')), '');
  st  text[];
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  st := case coalesce(p_status, 'proposed')
          when 'approved' then array['approved', 'undo_requested']
          when 'skipped' then array['skipped', 'undone']
          else array[coalesce(p_status, 'proposed')]
        end;
  select coalesce(jsonb_agg(x.row), '[]'::jsonb) into out
    from (
      select jsonb_build_object(
               'id', u.id, 'kind', u.kind, 'status', u.status, 'source', u.source,
               'batch', u.batch, 'note', u.note, 'impact', u.impact,
               'reason', public.upgrade_reason(v, u.kind),
               'before', u.before_text,
               'proposed', u.proposed_text,
               'final', u.final_text,
               'error', u.error,
               'created_at', u.created_at, 'decided_at', u.decided_at,
               'decided_by', u.decided_by, 'applied_at', u.applied_at,
               'venue_id', v.id, 'name', v.name, 'type', v.type,
               'area', coalesce(f.facts ->> 'area', v.neighbourhood),
               'region', f.facts ->> 'region',
               'country', v.country, 'slug', v.webflow_slug,
               'tier', v.listing_tier, 'owned', v.listing_owner_email is not null) as row
        from public.page_upgrades u
        join public.venues v on v.id = u.venue_id
        left join public.venue_page_facts f on f.venue_id = v.id
       where u.status = any(st)
         and (p_kind is null or p_kind = '' or u.kind = p_kind)
         and (q is null
              or v.name ilike '%' || q || '%'
              or coalesce(f.facts ->> 'area', v.neighbourhood, '') ilike '%' || q || '%'
              or coalesce(f.facts ->> 'region', '') ilike '%' || q || '%'
              or coalesce(v.country, '') ilike '%' || q || '%')
       order by case when u.status in ('applied', 'skipped', 'undone')
                     then extract(epoch from coalesce(u.applied_at, u.decided_at, u.created_at))
                     else 0 end desc,
                u.impact desc, u.created_at
       limit greatest(1, least(coalesce(p_limit, 60), 300))
    ) x;
  return out;
end $$;
revoke all on function public.admin_upgrades_list(text, text, text, integer) from public, anon;
grant execute on function public.admin_upgrades_list(text, text, text, integer) to authenticated;

-- Prepare the next p_n rule-built upgrades, highest impact first.
-- Only search descriptions are rule-built; the rest are drafted.
create or replace function public.admin_upgrades_prepare(p_kind text, p_n integer default 25)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n    integer := 0;
  made integer := 0;
  v    public.venues;
  txt  text;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if coalesce(p_kind, '') <> 'search_description' then
    raise exception 'Only search descriptions can be prepared straight away. Ask for a batch of the others.';
  end if;
  n := greatest(1, least(coalesce(p_n, 25), 200));
  for v in
    select x.* from public.venues x
     where public.upgrade_page_is_live(x)
       and public.upgrade_meta_is_generic(x)
       -- Skipped or undone pages are not proposed again by themselves;
       -- "Bring back" on the Skipped tab does that.
       and not exists (select 1 from public.page_upgrades u
                        where u.venue_id = x.id and u.kind = 'search_description')
     order by public.upgrade_impact(x, 'search_description') desc, x.name
  loop
    exit when made >= n;
    txt := public.upgrade_search_description(v);
    if public.upgrade_text_problem('search_description', txt) <> '' then
      continue;
    end if;
    insert into public.page_upgrades (venue_id, kind, before_text, proposed_text, source, impact)
    values (v.id, 'search_description', public.upgrade_current_meta(v), txt, 'rule',
            public.upgrade_impact(v, 'search_description'))
    on conflict do nothing;
    if found then made := made + 1; end if;
  end loop;
  return made;
end $$;
revoke all on function public.admin_upgrades_prepare(text, integer) from public, anon;
grant execute on function public.admin_upgrades_prepare(text, integer) to authenticated;

-- Go: approve one upgrade, with the founder's edit if there is one.
create or replace function public.admin_upgrade_go(p_id uuid, p_text text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  u    public.page_upgrades;
  txt  text;
  prob text;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into u from public.page_upgrades where id = p_id for update;
  if u.id is null then
    raise exception 'That upgrade could not be found.';
  end if;
  if u.status not in ('proposed', 'failed') then
    raise exception 'This one has already been decided.';
  end if;
  -- An earlier edit is kept when Go is pressed again (after a failed
  -- write, or after taking it back).
  txt := coalesce(nullif(trim(coalesce(p_text, '')), ''), u.final_text, u.proposed_text);
  if u.kind = 'search_description' then
    txt := regexp_replace(trim(txt), '\s+', ' ', 'g');
  end if;
  prob := public.upgrade_text_problem(u.kind, txt);
  if prob <> '' then
    raise exception '%', prob;
  end if;
  update public.page_upgrades
     set status = 'approved', final_text = txt, error = null,
         decided_at = now(), decided_by = public.upgrades_admin_email()
   where id = p_id;
  perform public.upgrades_nudge();
end $$;
revoke all on function public.admin_upgrade_go(uuid, text) from public, anon;
grant execute on function public.admin_upgrade_go(uuid, text) to authenticated;

-- Go for several at once, as proposed. Returns how many were approved.
create or replace function public.admin_upgrades_go_many(p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  update public.page_upgrades u
     set status = 'approved',
         final_text = case when u.kind = 'search_description'
                           then regexp_replace(trim(coalesce(u.final_text, u.proposed_text)),
                                               '\s+', ' ', 'g')
                           else coalesce(u.final_text, u.proposed_text) end,
         error = null, decided_at = now(), decided_by = public.upgrades_admin_email()
   where u.id = any(coalesce(p_ids, '{}'::uuid[]))
     and u.status in ('proposed', 'failed')
     and public.upgrade_text_problem(u.kind, coalesce(u.final_text, u.proposed_text)) = '';
  get diagnostics n = row_count;
  if n > 0 then
    perform public.upgrades_nudge();
  end if;
  return n;
end $$;
revoke all on function public.admin_upgrades_go_many(uuid[]) from public, anon;
grant execute on function public.admin_upgrades_go_many(uuid[]) to authenticated;

-- Skip: not this one. It stays as history and is not proposed again.
create or replace function public.admin_upgrade_skip(p_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  update public.page_upgrades
     set status = 'skipped', decided_at = now(), decided_by = public.upgrades_admin_email(),
         note = coalesce(nullif(left(trim(coalesce(p_note, '')), 1000), ''), note)
   where id = p_id and status in ('proposed', 'failed');
  if not found then
    raise exception 'This one has already been decided.';
  end if;
end $$;
revoke all on function public.admin_upgrade_skip(uuid, text) from public, anon;
grant execute on function public.admin_upgrade_skip(uuid, text) to authenticated;

-- Undo. Approved but not on the site yet: back to waiting. On the
-- site: the push puts the old text back. Skipped or undone ("Bring
-- back"): back to waiting.
create or replace function public.admin_upgrade_undo(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  u public.page_upgrades;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into u from public.page_upgrades where id = p_id for update;
  if u.id is null then
    raise exception 'That upgrade could not be found.';
  end if;
  if u.status = 'approved' then
    if u.writing_since is not null and u.writing_since > now() - interval '10 minutes' then
      raise exception 'This one is being written to the page right now. Give it a minute, then use Undo on the Live tab.';
    end if;
    update public.page_upgrades
       set status = 'proposed', decided_at = null, decided_by = null, writing_since = null
     where id = p_id;
    return 'proposed';
  elsif u.status = 'applied' then
    update public.page_upgrades set status = 'undo_requested', error = null where id = p_id;
    perform public.upgrades_nudge();
    return 'undo_requested';
  elsif u.status in ('skipped', 'undone') then
    if exists (select 1 from public.page_upgrades o
                where o.venue_id = u.venue_id and o.kind = u.kind and o.id <> u.id
                  and o.status in ('proposed', 'approved', 'applied', 'failed', 'undo_requested')) then
      raise exception 'There is already a newer upgrade of this kind for this page.';
    end if;
    begin
      update public.page_upgrades
         set status = 'proposed', decided_at = null, decided_by = null, final_text = null,
             previous_value = null, error = null, writing_since = null
       where id = p_id;
    exception when unique_violation then
      raise exception 'There is already a newer upgrade of this kind for this page.';
    end;
    return 'proposed';
  end if;
  raise exception 'There is nothing to undo here.';
end $$;
revoke all on function public.admin_upgrade_undo(uuid) from public, anon;
grant execute on function public.admin_upgrade_undo(uuid) to authenticated;

-- Ask for more of a kind. One open request per kind: asking again
-- changes the number and the note.
create or replace function public.admin_upgrade_request(
  p_kind text, p_n integer default 20, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  n   integer := greatest(1, least(coalesce(p_n, 20), 200));
  nt  text := nullif(left(trim(coalesce(p_note, '')), 1000), '');
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if coalesce(p_kind, '') not in ('search_description', 'description', 'prices', 'wifi', 'other') then
    raise exception 'That is not a kind of upgrade.';
  end if;
  select id into rid from public.upgrade_requests
   where kind = p_kind and status = 'open' order by created_at limit 1;
  if rid is not null then
    update public.upgrade_requests
       set how_many = n, note = nt, asked_by = public.upgrades_admin_email(),
           created_at = now()
     where id = rid;
    return rid;
  end if;
  insert into public.upgrade_requests (kind, how_many, note, asked_by)
  values (p_kind, n, nt, public.upgrades_admin_email())
  returning id into rid;
  return rid;
end $$;
revoke all on function public.admin_upgrade_request(text, integer, text) from public, anon;
grant execute on function public.admin_upgrade_request(text, integer, text) to authenticated;

create or replace function public.admin_upgrade_request_cancel(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  update public.upgrade_requests set status = 'cancelled', done_at = now()
   where id = p_id and status = 'open';
end $$;
revoke all on function public.admin_upgrade_request_cancel(uuid) from public, anon;
grant execute on function public.admin_upgrade_request_cancel(uuid) to authenticated;

-- ------------------------------------------------------ the sync's side

-- What the nightly sync saw on each page: [{"cms_id": "...", "facts": {...}}].
create or replace function public.set_page_facts(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if jsonb_typeof(p) <> 'array' then
    return 0;
  end if;
  insert into public.venue_page_facts (venue_id, facts, updated_at)
  select distinct on (v.id) v.id, x.facts, now()
    from (select e ->> 'cms_id' as cms_id, e -> 'facts' as facts
            from jsonb_array_elements(p) e
           where jsonb_typeof(e -> 'facts') = 'object'
             and coalesce(e ->> 'cms_id', '') <> '') x
    join public.venues v on v.webflow_cms_id = x.cms_id
   order by v.id
  on conflict (venue_id) do update
    set facts = excluded.facts, updated_at = excluded.updated_at;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_page_facts(jsonb) from public, anon, authenticated;
grant execute on function public.set_page_facts(jsonb) to service_role;

-- Page views per listing page: [{"slug": "...", "views": 12, "visitors": 9}].
create or replace function public.set_page_popularity(p jsonb, p_days integer default 90)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if jsonb_typeof(p) <> 'array' then
    return 0;
  end if;
  insert into public.page_popularity (slug, views, visitors, days, measured_at)
  select distinct on (e ->> 'slug')
         e ->> 'slug', greatest(coalesce((e ->> 'views')::int, 0), 0),
         greatest(coalesce((e ->> 'visitors')::int, 0), 0),
         greatest(coalesce(p_days, 90), 1), now()
    from jsonb_array_elements(p) e
   where coalesce(e ->> 'slug', '') <> ''
   order by e ->> 'slug', coalesce((e ->> 'views')::int, 0) desc
  on conflict (slug) do update
    set views = excluded.views, visitors = excluded.visitors,
        days = excluded.days, measured_at = excluded.measured_at;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_page_popularity(jsonb, integer) from public, anon, authenticated;
grant execute on function public.set_page_popularity(jsonb, integer) to service_role;

-- Drafted upgrades, loaded by a later migration:
-- [{"slug": "...", "kind": "description", "text": "...", "note": "..."}].
-- A page that already has a live proposal of that kind, or an owner
-- (who writes their own description), is left alone. Open requests of
-- the kinds that arrived are closed.
create or replace function public.import_page_upgrades(p jsonb, p_batch text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e       jsonb;
  v       public.venues;
  kind_   text;
  txt     text;
  added   integer := 0;
  skipped jsonb := '[]'::jsonb;
  kinds   text[] := '{}';
begin
  if jsonb_typeof(p) <> 'array' then
    return jsonb_build_object('added', 0, 'skipped', '[]'::jsonb);
  end if;
  for e in select * from jsonb_array_elements(p) loop
    kind_ := coalesce(e ->> 'kind', '');
    txt := coalesce(e ->> 'text', '');
    select * into v from public.venues x where x.webflow_slug = e ->> 'slug' limit 1;
    if v.id is null then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'why', 'no page with that address');
      continue;
    end if;
    if kind_ not in ('search_description', 'description') then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'why', 'unknown kind');
      continue;
    end if;
    if kind_ = 'description' and v.listing_owner_email is not null then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'why', 'the owner writes this page');
      continue;
    end if;
    if public.upgrade_text_problem(kind_, txt) <> '' then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug',
                                               'why', public.upgrade_text_problem(kind_, txt));
      continue;
    end if;
    if exists (select 1 from public.page_upgrades u
                where u.venue_id = v.id and u.kind = kind_
                  and u.status in ('proposed', 'approved', 'applied', 'failed', 'undo_requested')) then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'why', 'already has one');
      continue;
    end if;
    insert into public.page_upgrades (venue_id, kind, before_text, proposed_text, source,
                                      batch, note, impact)
    values (v.id, kind_,
            case when kind_ = 'search_description' then public.upgrade_current_meta(v)
                 else nullif(e ->> 'before', '') end,
            txt, 'drafted', nullif(coalesce(p_batch, e ->> 'batch', ''), ''),
            nullif(left(coalesce(e ->> 'note', ''), 1000), ''),
            public.upgrade_impact(v, kind_))
    on conflict do nothing;
    if not found then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'why', 'already has one');
      continue;
    end if;
    added := added + 1;
    if not kind_ = any(kinds) then kinds := kinds || kind_; end if;
  end loop;
  if added > 0 then
    update public.upgrade_requests set status = 'done', done_at = now()
     where status = 'open' and kind = any(kinds);
  end if;
  return jsonb_build_object('added', added, 'skipped', skipped);
end $$;
revoke all on function public.import_page_upgrades(jsonb, text) from public, anon, authenticated;
grant execute on function public.import_page_upgrades(jsonb, text) to service_role;

-- What the website push should write now: approved upgrades and
-- undos, oldest decision first.
create or replace function public.upgrades_to_apply(p_limit integer default 40)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.row), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'id', u.id, 'kind', u.kind, 'status', u.status,
               'final_text', u.final_text, 'previous_value', u.previous_value,
               'name', v.name, 'webflow_cms_id', v.webflow_cms_id,
               'owned', v.listing_owner_email is not null) as row
        from public.page_upgrades u
        join public.venues v on v.id = u.venue_id
       where u.status in ('approved', 'undo_requested')
         and v.webflow_cms_id is not null
       order by u.decided_at nulls last, u.created_at
       limit greatest(1, least(coalesce(p_limit, 40), 200))
    ) x
$$;
revoke all on function public.upgrades_to_apply(integer) from public, anon, authenticated;
grant execute on function public.upgrades_to_apply(integer) to service_role;

-- Merge a few keys into what we hold about a venue's page.
create or replace function public.upgrade_facts_merge(p_venue uuid, p_more jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.venue_page_facts (venue_id, facts, updated_at)
  values (p_venue, coalesce(p_more, '{}'::jsonb), now())
  on conflict (venue_id) do update
    set facts = public.venue_page_facts.facts || excluded.facts
$$;
revoke all on function public.upgrade_facts_merge(uuid, jsonb) from public, anon, authenticated;

-- The push claims a row just before it writes to the page. False
-- means the founder took it back or reworded it since the run read
-- it, and the push leaves the page alone. The text on the page before
-- the first write is kept here, so a retry never mistakes the new
-- text for the old.
create or replace function public.upgrade_begin(p_id uuid, p_text text, p_previous text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.page_upgrades
     set writing_since = now(),
         previous_value = case when status = 'approved'
                               then coalesce(previous_value, p_previous, '')
                               else previous_value end
   where id = p_id
     and status in ('approved', 'undo_requested')
     and final_text is not distinct from p_text;
  return found;
end $$;
revoke all on function public.upgrade_begin(uuid, text, text) from public, anon, authenticated;
grant execute on function public.upgrade_begin(uuid, text, text) to service_role;

-- The push reports back. p_previous is what was on the page before
-- the write (kept for Undo unless upgrade_begin already has it);
-- p_words is the description's length afterwards. A row the founder
-- has moved on in the meantime is left as it is.
create or replace function public.upgrade_done(
  p_id uuid, p_ok boolean, p_previous text default null,
  p_error text default null, p_words integer default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  u public.page_upgrades;
begin
  select * into u from public.page_upgrades where id = p_id for update;
  if u.id is null or u.status not in ('approved', 'undo_requested') then
    return;
  end if;
  if not coalesce(p_ok, false) then
    -- A failed write keeps its text and goes back to the founder; a
    -- failed undo stays applied, with the reason.
    update public.page_upgrades
       set status = case when u.status = 'undo_requested' then 'applied' else 'failed' end,
           error = left(coalesce(p_error, 'The website did not accept it.'), 400),
           writing_since = null
     where id = p_id;
    return;
  end if;
  if u.status = 'approved' then
    update public.page_upgrades
       set status = 'applied', applied_at = now(), error = null, writing_since = null,
           previous_value = coalesce(previous_value, p_previous)
     where id = p_id;
    if u.kind = 'search_description' then
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('meta', u.final_text, 'meta_generic', false));
    else
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('desc_words', greatest(coalesce(p_words, 1), 1)));
    end if;
  else
    update public.page_upgrades
       set status = 'undone', applied_at = null, error = null, decided_at = now(),
           writing_since = null
     where id = p_id;
    if u.kind = 'search_description' then
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object(
          'meta', coalesce(u.previous_value, ''),
          'meta_generic', coalesce(u.previous_value, '') ilike
            'Find cafes & coworking spaces for digital nomads%'));
    else
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('desc_words', greatest(coalesce(p_words, 0), 0)));
    end if;
  end if;
end $$;
revoke all on function public.upgrade_done(uuid, boolean, text, text, integer) from public, anon, authenticated;
grant execute on function public.upgrade_done(uuid, boolean, text, text, integer) to service_role;

-- For the nightly sync report (readable on the sync-reports branch):
-- what has been asked for and where the queue stands. No page text.
create or replace function public.upgrades_report()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'open_requests', (select coalesce(jsonb_agg(jsonb_build_object(
                         'kind', r.kind, 'how_many', r.how_many, 'note', r.note,
                         'asked_at', r.created_at) order by r.created_at), '[]'::jsonb)
                        from public.upgrade_requests r where r.status = 'open'),
    'queue', (select coalesce(jsonb_object_agg(s.k, s.n), '{}'::jsonb)
                from (select kind || ':' || status as k, count(*) n
                        from public.page_upgrades group by 1) s),
    'drafted_slugs', (select coalesce(jsonb_agg(v.webflow_slug), '[]'::jsonb)
                        from public.page_upgrades u join public.venues v on v.id = u.venue_id
                       where u.kind = 'description' and u.status <> 'undone'))
$$;
revoke all on function public.upgrades_report() from public, anon, authenticated;
grant execute on function public.upgrades_report() to service_role;
