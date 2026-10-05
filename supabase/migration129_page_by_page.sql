-- ============================================================
-- Migration 129: Page upgrades, one page at a time.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan (4 Oct 2026): the photos part works the way he wants. For
-- the text he does not want batches. He wants to take one page, see
-- what it says now next to what is proposed, and press Go for each
-- part himself; and he wants the proposals to come from what people
-- search for (Ahrefs), not from a formula.
--
-- So in this migration:
--   * the batch paths go: "Prepare more" (admin_upgrades_prepare),
--     "Go for all shown" (admin_upgrades_go_many) and "Ask for a
--     batch" (admin_upgrade_request) are dropped;
--   * a page can be asked for by itself ("Request upgrade", kept in
--     upgrade_requests with its venue), and the open requests are in
--     the nightly sync report so they can be drafted in a session;
--   * admin_upgrades_pages() lists the live pages, the most promising
--     first, and admin_upgrade_page() gives one page whole: for the
--     title, the search description and the page description, what is
--     on the page now and the upgrade, if there is one;
--   * a third text part, the page title (Webflow: Title Tag), can be
--     upgraded like the other two;
--   * page_search holds what each page ranks for on Google and how
--     often that is searched (from Ahrefs, loaded by a migration), so
--     the list can say why a page is worth doing and put it higher;
--   * a founder can write a part himself (admin_upgrade_write), and
--     build the plain search description for one page
--     (admin_upgrade_prepare_one);
--   * a newer draft replaces one that was still waiting. One that is
--     live stays live, and can be undone, until a newer one is
--     written over it; only then does it become history
--     ("superseded"). For that, a page and part can now hold one
--     change that is waiting and one that is live at the same time.
-- Structure and design of the page template are not handled here on
-- purpose: they are one change in Webflow for every page, and live in
-- docs/LISTING_TEMPLATE.md.
-- ============================================================

alter table public.page_upgrades drop constraint if exists page_upgrades_kind_check;
alter table public.page_upgrades add constraint page_upgrades_kind_check
  check (kind in ('search_description', 'description', 'photos', 'title'));
-- Room on a card for what a draft was based on.
alter table public.page_upgrades drop constraint if exists page_upgrades_note_check;
alter table public.page_upgrades add constraint page_upgrades_note_check
  check (char_length(note) <= 2000);

-- One waiting change and one live change per page and part (before:
-- one of either), so a draft can wait next to the version that is on
-- the page without taking away its Undo.
drop index if exists public.idx_page_upgrades_one_open;
create unique index if not exists idx_page_upgrades_one_waiting
  on public.page_upgrades(venue_id, kind)
  where status in ('proposed', 'approved', 'failed');
create unique index if not exists idx_page_upgrades_one_live
  on public.page_upgrades(venue_id, kind)
  where status in ('applied', 'undo_requested');

alter table public.upgrade_requests
  add column if not exists venue_id uuid references public.venues(id) on delete cascade;
alter table public.upgrade_requests drop constraint if exists upgrade_requests_kind_check;
alter table public.upgrade_requests add constraint upgrade_requests_kind_check
  check (kind in ('search_description', 'description', 'prices', 'wifi', 'other', 'page'));
create unique index if not exists idx_upgrade_requests_one_page
  on public.upgrade_requests(venue_id)
  where status = 'open' and venue_id is not null;
-- The batch requests are gone with the batch buttons.
update public.upgrade_requests
   set status = 'cancelled', done_at = now()
 where status = 'open' and venue_id is null;

-- What a page ranks for on Google: one row per page, search and
-- country. A snapshot, replaced whole each time it is loaded.
create table if not exists public.page_search (
  slug         text not null,
  keyword      text not null,
  country      text not null default '',
  position     integer,
  volume       integer not null default 0,
  measured_at  timestamptz not null default now(),
  primary key (slug, keyword, country)
);
alter table public.page_search enable row level security;
drop policy if exists "page_search admin" on public.page_search;
create policy "page_search admin" on public.page_search
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- [{"slug": "...", "keyword": "...", "position": 7, "volume": 5300, "country": "ID"}]
create or replace function public.set_page_search(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if jsonb_typeof(p) <> 'array' then
    return 0;
  end if;
  delete from public.page_search where true;
  insert into public.page_search (slug, keyword, country, position, volume, measured_at)
  select distinct on (e ->> 'slug', lower(trim(e ->> 'keyword')), coalesce(e ->> 'country', ''))
         e ->> 'slug', lower(trim(e ->> 'keyword')), coalesce(e ->> 'country', ''),
         nullif(e ->> 'position', '')::int,
         greatest(coalesce(nullif(e ->> 'volume', '')::int, 0), 0), now()
    from jsonb_array_elements(p) e
   where coalesce(e ->> 'slug', '') <> '' and coalesce(trim(e ->> 'keyword'), '') <> ''
   order by e ->> 'slug', lower(trim(e ->> 'keyword')), coalesce(e ->> 'country', ''),
            coalesce(nullif(e ->> 'volume', '')::int, 0) desc;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_page_search(jsonb) from public, anon, authenticated;
grant execute on function public.set_page_search(jsonb) to service_role;

-- The searches a page ranks for, the most searched first.
create or replace function public.upgrade_searches(p_slug text, p_limit integer default 5)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'keyword', x.keyword, 'position', x.position, 'volume', x.volume,
           'country', x.country) order by x.volume desc, x.position), '[]'::jsonb)
    from (select s.keyword, s.position, s.volume, s.country
            from public.page_search s
           where s.slug = p_slug
           order by s.volume desc, s.position
           limit greatest(1, least(coalesce(p_limit, 5), 20))) x
$$;

-- In words, for the most searched one: position 7 on Google for
-- "alchemy uluwatu" (5,300 searches a month). Null when none.
create or replace function public.upgrade_search_line(p_slug text)
returns text language sql stable set search_path = public as $$
  select 'position ' || coalesce(s.position::text, '?') || ' on Google for "' || s.keyword
         || '" (' || trim(to_char(s.volume, 'FM999,999,999')) || ' searches a month)'
    from public.page_search s
   where s.slug = p_slug
   order by s.volume desc, s.position
   limit 1
$$;

-- How much a change to this page is likely to matter. As before
-- (page views, how well known the place is, coworking a quarter
-- more), plus what the page already ranks for: a page sitting below
-- the top spot for a search people make has the most to gain.
create or replace function public.upgrade_impact(v public.venues, p_kind text)
returns numeric language plpgsql stable set search_path = public as $$
declare
  vw integer := 0;
  sb numeric := 0;
  s  numeric;
begin
  select coalesce(p.views, 0) into vw from public.page_popularity p where p.slug = v.webflow_slug;
  select max(case when coalesce(x.position, 99) between 2 and 30
                  then 6 * ln(1 + x.volume) else 3 * ln(1 + x.volume) end)
    into sb
    from public.page_search x where x.slug = v.webflow_slug;
  s := 10 * ln(1 + coalesce(vw, 0))
     + 2 * ln(1 + greatest(coalesce(v.google_reviews_snapshot, 0), 0))
     + coalesce(sb, 0);
  if v.type = 'coworking' then s := s * 1.25; end if;
  if p_kind = 'search_description' then s := s * 0.8; end if;
  return round(s, 1);
end $$;

-- Why this page is where it is in the list, in plain words.
create or replace function public.upgrade_reason(v public.venues, p_kind text)
returns text language plpgsql stable set search_path = public as $$
declare
  vw   integer;
  days integer;
  sl   text;
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
  sl := public.upgrade_search_line(v.webflow_slug);
  if sl is not null then
    out := out || ' · ' || sl;
  end if;
  return out;
end $$;

-- What may not go on a page. Returns '' when the text is fine.
create or replace function public.upgrade_text_problem(p_kind text, p_text text)
returns text language plpgsql immutable as $$
declare
  t    text := coalesce(p_text, '');
  urls text[];
  u    text;
begin
  if trim(t) = '' then
    return 'There is nothing to put on the page.';
  end if;
  if p_kind = 'photos' then
    urls := public.upgrade_photo_list(t);
    if urls is null or coalesce(array_length(urls, 1), 0) = 0 then
      return 'Add at least one photo.';
    end if;
    if array_length(urls, 1) > 5 then
      return 'A page holds five photos at most.';
    end if;
    foreach u in array urls loop
      if u !~* '^https?://[^\s]+$' then
        return 'Each photo has to be a link starting with https://. Right-click the photo and choose "Copy image address".';
      end if;
      if char_length(u) > 1500 then
        return 'One of the links is too long to be an image address.';
      end if;
    end loop;
    if (select count(distinct x) from unnest(urls) x) < array_length(urls, 1) then
      return 'The same photo is in there twice.';
    end if;
    return '';
  end if;
  if t ~ '[—–]' then
    return 'Please take out the long dash; the site does not use them.';
  end if;
  if p_kind = 'title' then
    if t ~ E'[\\n\\r]' then
      return 'A title is a single line.';
    end if;
    if char_length(trim(t)) < 10 then
      return 'That is too short for a page title.';
    end if;
    if char_length(trim(t)) > 80 then
      return 'That is too long; Google shows about 60 characters of a title.';
    end if;
    if t ~ '<[a-zA-Z/]' then
      return 'Plain text only in a title.';
    end if;
  elsif p_kind = 'search_description' then
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

-- What is on the page now for one text part, as far as we know it.
-- Null means not known: the page has not been read since the sync
-- started keeping titles ("title") and page text ("desc"). Each key
-- answers only for itself, so a title changed here does not make an
-- unread description look empty.
create or replace function public.upgrade_current(v public.venues, p_kind text)
returns text language sql stable set search_path = public as $$
  select case
    when x.f is null then null
    when p_kind = 'search_description' then public.upgrade_current_meta(v)
    when p_kind = 'title' then x.f ->> 'title'
    when p_kind = 'description' then x.f ->> 'desc'
    else null
  end
  from (select public.upgrade_facts(v.id) as f) x
$$;

-- ------------------------------------------------------------ the list

-- Live pages, the most promising first. p_filter: '' (all),
-- 'requested' (an upgrade has been asked for), 'waiting' (a text
-- upgrade is waiting for a Go), 'search' (pages that rank for a
-- search people make).
create or replace function public.admin_upgrades_pages(
  p_q text default null, p_filter text default null, p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q   text := nullif(trim(coalesce(p_q, '')), '');
  flt text := coalesce(p_filter, '');
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select coalesce(jsonb_agg(x.row), '[]'::jsonb) into out
    from (
      select jsonb_build_object(
               'venue_id', v.id, 'name', v.name, 'type', v.type,
               'area', coalesce(f.facts ->> 'area', v.neighbourhood),
               'region', f.facts ->> 'region',
               'country', v.country, 'slug', v.webflow_slug,
               'owned', v.listing_owner_email is not null,
               'impact', public.upgrade_impact(v, 'description'),
               'reason', public.upgrade_reason(v, 'description'),
               'title', f.facts ->> 'title',
               'meta_generic', public.upgrade_meta_is_generic(v),
               'desc_words', coalesce((f.facts ->> 'desc_words')::int, 0),
               'photos', (f.facts ->> 'photos')::int,
               'request', (select jsonb_build_object('id', r.id, 'note', r.note,
                                                     'created_at', r.created_at)
                             from public.upgrade_requests r
                            where r.venue_id = v.id and r.status = 'open' limit 1),
               'waiting', (select count(*) from public.page_upgrades u
                            where u.venue_id = v.id and u.kind <> 'photos'
                              and u.status = 'proposed'),
               'on_way', (select count(*) from public.page_upgrades u
                           where u.venue_id = v.id and u.kind <> 'photos'
                             and u.status in ('approved', 'undo_requested')),
               'live', (select count(*) from public.page_upgrades u
                         where u.venue_id = v.id and u.kind <> 'photos'
                           and u.status = 'applied'),
               'failed', (select count(*) from public.page_upgrades u
                           where u.venue_id = v.id and u.kind <> 'photos'
                             and u.status = 'failed')) as row
        from public.venues v
        left join public.venue_page_facts f on f.venue_id = v.id
       where public.upgrade_page_is_live(v)
         and (q is null
              or v.name ilike '%' || q || '%'
              or coalesce(v.webflow_slug, '') ilike '%' || q || '%'
              or coalesce(f.facts ->> 'area', v.neighbourhood, '') ilike '%' || q || '%'
              or coalesce(f.facts ->> 'region', '') ilike '%' || q || '%'
              or coalesce(v.country, '') ilike '%' || q || '%')
         and (flt <> 'requested'
              or exists (select 1 from public.upgrade_requests r
                          where r.venue_id = v.id and r.status = 'open'))
         and (flt <> 'waiting'
              or exists (select 1 from public.page_upgrades u
                          where u.venue_id = v.id and u.kind <> 'photos'
                            and u.status in ('proposed', 'failed')))
         and (flt <> 'search'
              or exists (select 1 from public.page_search s where s.slug = v.webflow_slug))
       order by public.upgrade_impact(v, 'description') desc, v.name
       limit greatest(1, least(coalesce(p_limit, 60), 300))
    ) x;
  return out;
end $$;
revoke all on function public.admin_upgrades_pages(text, text, integer) from public, anon;
grant execute on function public.admin_upgrades_pages(text, text, integer) to authenticated;

-- One page, whole: the three text parts with what is on the page now
-- and the newest upgrade of each, the searches it ranks for, and any
-- open request.
create or replace function public.admin_upgrade_page(p_venue uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v     public.venues;
  f     jsonb;
  parts jsonb := '[]'::jsonb;
  k     text;
  up    jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into v from public.venues where id = p_venue;
  if v.id is null then
    raise exception 'That page could not be found.';
  end if;
  f := coalesce(public.upgrade_facts(v.id), '{}'::jsonb);
  foreach k in array array['title', 'search_description', 'description'] loop
    -- The one that is waiting or on its way if there is one, then
    -- the one that is live; otherwise the newest skipped or undone
    -- one, so it can be brought back.
    select jsonb_build_object(
             'id', u.id, 'kind', u.kind, 'status', u.status, 'source', u.source,
             'before', u.before_text, 'proposed', u.proposed_text, 'final', u.final_text,
             'note', u.note, 'error', u.error, 'batch', u.batch,
             'created_at', u.created_at, 'decided_at', u.decided_at,
             'applied_at', u.applied_at, 'venue_id', v.id, 'name', v.name)
      into up
      from public.page_upgrades u
     where u.venue_id = v.id and u.kind = k and u.status <> 'superseded'
     order by case when u.status in ('proposed', 'approved', 'failed') then 0
                   when u.status in ('applied', 'undo_requested') then 1
                   else 2 end,
              u.created_at desc
     limit 1;
    parts := parts || jsonb_build_object(
      'kind', k,
      'current', public.upgrade_current(v, k),
      'read', public.upgrade_current(v, k) is not null,
      'upgrade', up);
    up := null;
  end loop;
  return jsonb_build_object(
    'venue_id', v.id, 'name', v.name, 'type', v.type,
    'area', coalesce(f ->> 'area', v.neighbourhood), 'region', f ->> 'region',
    'country', v.country, 'slug', v.webflow_slug,
    'live', public.upgrade_page_is_live(v),
    'owned', v.listing_owner_email is not null,
    'reason', public.upgrade_reason(v, 'description'),
    'searches', public.upgrade_searches(v.webflow_slug, 6),
    'photos', (f ->> 'photos')::int,
    'request', (select jsonb_build_object('id', r.id, 'note', r.note, 'created_at', r.created_at)
                  from public.upgrade_requests r
                 where r.venue_id = v.id and r.status = 'open' limit 1),
    'parts', parts);
end $$;
revoke all on function public.admin_upgrade_page(uuid) from public, anon;
grant execute on function public.admin_upgrade_page(uuid) to authenticated;

-- ------------------------------------------------------------ requests

-- "Request upgrade" for one page. Asking again changes the note.
create or replace function public.admin_upgrade_page_request(p_venue uuid, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v   public.venues;
  rid uuid;
  nt  text := nullif(left(trim(coalesce(p_note, '')), 1000), '');
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into v from public.venues where id = p_venue;
  if v.id is null or not public.upgrade_page_is_live(v) then
    raise exception 'That page is not live on the website.';
  end if;
  select id into rid from public.upgrade_requests
   where venue_id = v.id and status = 'open' limit 1;
  if rid is not null then
    update public.upgrade_requests
       set note = nt, asked_by = public.upgrades_admin_email()
     where id = rid;
    return rid;
  end if;
  begin
    insert into public.upgrade_requests (kind, how_many, note, asked_by, venue_id)
    values ('page', 1, nt, public.upgrades_admin_email(), v.id)
    returning id into rid;
  exception when unique_violation then
    select id into rid from public.upgrade_requests
     where venue_id = v.id and status = 'open' limit 1;
  end;
  return rid;
end $$;
revoke all on function public.admin_upgrade_page_request(uuid, text) from public, anon;
grant execute on function public.admin_upgrade_page_request(uuid, text) to authenticated;

create or replace function public.admin_upgrade_page_request_cancel(p_venue uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  update public.upgrade_requests set status = 'cancelled', done_at = now()
   where venue_id = p_venue and status = 'open';
end $$;
revoke all on function public.admin_upgrade_page_request_cancel(uuid) from public, anon;
grant execute on function public.admin_upgrade_page_request_cancel(uuid) to authenticated;

-- ------------------------------------------------- one page, by hand

-- The plain search description for one page, built from the facts we
-- hold, as a proposal to look at (it is not sent anywhere). A version
-- that is live stays as it is until this one is written over it.
create or replace function public.admin_upgrade_prepare_one(p_venue uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v     public.venues;
  live_ public.page_upgrades;
  txt   text;
  prob  text;
  rid   uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into v from public.venues where id = p_venue;
  if v.id is null or not public.upgrade_page_is_live(v) then
    raise exception 'That page is not live on the website.';
  end if;
  if exists (select 1 from public.page_upgrades u
              where u.venue_id = v.id and u.kind = 'search_description'
                and u.status in ('proposed', 'approved', 'failed')) then
    raise exception 'There is already a search description waiting for this page.';
  end if;
  select * into live_ from public.page_upgrades u
   where u.venue_id = v.id and u.kind = 'search_description' and u.status = 'applied'
   limit 1;
  txt := public.upgrade_search_description(v);
  prob := public.upgrade_text_problem('search_description', txt);
  if prob <> '' then
    raise exception '%', prob;
  end if;
  if txt = coalesce(live_.final_text, public.upgrade_current_meta(v), '') then
    raise exception 'That is the search description already on the page.';
  end if;
  begin
    insert into public.page_upgrades (venue_id, kind, before_text, proposed_text, source, impact)
    values (v.id, 'search_description',
            coalesce(live_.final_text, public.upgrade_current_meta(v)), txt, 'rule',
            public.upgrade_impact(v, 'search_description'))
    returning id into rid;
  exception when unique_violation then
    raise exception 'There is already a search description waiting for this page.';
  end;
  return rid;
end $$;
revoke all on function public.admin_upgrade_prepare_one(uuid) from public, anon;
grant execute on function public.admin_upgrade_prepare_one(uuid) to authenticated;

-- A founder's own wording for one text part of one page. Saving is
-- the Go, as with photos: the row is approved at once and the push
-- writes it. One still waiting for the page is reworded. A version
-- that is live stays live, with its Undo, until this one is written
-- over it.
create or replace function public.admin_upgrade_write(p_venue uuid, p_kind text, p_text text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v     public.venues;
  pend  public.page_upgrades;
  live_ public.page_upgrades;
  txt   text := coalesce(p_text, '');
  prob  text;
  rid   uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if coalesce(p_kind, '') not in ('title', 'search_description', 'description') then
    raise exception 'That part of the page cannot be written here.';
  end if;
  select * into v from public.venues where id = p_venue;
  if v.id is null or not public.upgrade_page_is_live(v) then
    raise exception 'That page is not live on the website.';
  end if;
  if p_kind = 'description' and v.listing_owner_email is not null then
    raise exception 'This page has an owner, who writes its description in the Owner account.';
  end if;
  if p_kind in ('title', 'search_description') then
    txt := regexp_replace(trim(txt), '\s+', ' ', 'g');
  end if;
  prob := public.upgrade_text_problem(p_kind, txt);
  if prob <> '' then
    raise exception '%', prob;
  end if;
  select * into live_ from public.page_upgrades u
   where u.venue_id = v.id and u.kind = p_kind
     and u.status in ('applied', 'undo_requested')
   limit 1;
  if live_.status = 'undo_requested' then
    raise exception 'The earlier version of this part is being put back right now. Give it a minute and try again.';
  end if;
  select * into pend from public.page_upgrades u
   where u.venue_id = v.id and u.kind = p_kind
     and u.status in ('proposed', 'approved', 'failed')
   limit 1 for update;
  if pend.id is not null then
    if pend.writing_since is not null
       and pend.writing_since > now() - interval '10 minutes' then
      raise exception 'This part of the page is being written right now. Give it a minute and try again.';
    end if;
    update public.page_upgrades
       set status = 'approved', final_text = txt, error = null,
           decided_at = now(), decided_by = public.upgrades_admin_email(),
           writing_since = null
     where id = pend.id;
    perform public.upgrades_nudge();
    return pend.id;
  end if;
  if txt = coalesce(live_.final_text, public.upgrade_current(v, p_kind), '') then
    raise exception 'That is what the page says already.';
  end if;
  begin
    insert into public.page_upgrades (venue_id, kind, status, before_text, proposed_text,
                                      final_text, source, impact, decided_at, decided_by)
    values (v.id, p_kind, 'approved',
            coalesce(live_.final_text, public.upgrade_current(v, p_kind)), txt, txt, 'founder',
            public.upgrade_impact(v, p_kind), now(), public.upgrades_admin_email())
    returning id into rid;
  exception when unique_violation then
    raise exception 'Someone else has just changed this part of the page. Refresh and try again.';
  end;
  perform public.upgrades_nudge();
  return rid;
end $$;
revoke all on function public.admin_upgrade_write(uuid, text, text) from public, anon;
grant execute on function public.admin_upgrade_write(uuid, text, text) to authenticated;

-- Go: approve one upgrade, with the founder's edit if there is one.
-- (As in migration 125, with the title tidied like a single line.)
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
  txt := coalesce(nullif(trim(coalesce(p_text, '')), ''), u.final_text, u.proposed_text);
  if u.kind in ('search_description', 'title') then
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

-- Undo, as in migration 125. Bringing back a skipped or undone
-- upgrade is now refused only when another one is waiting for the
-- same part; a live one no longer stands in the way.
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
                  and o.status in ('proposed', 'approved', 'failed')) then
      raise exception 'There is already a newer upgrade of this kind waiting for this page.';
    end if;
    begin
      update public.page_upgrades
         set status = 'proposed', decided_at = null, decided_by = null, final_text = null,
             previous_value = null, error = null, writing_since = null
       where id = p_id;
    exception when unique_violation then
      raise exception 'There is already a newer upgrade of this kind waiting for this page.';
    end;
    return 'proposed';
  end if;
  raise exception 'There is nothing to undo here.';
end $$;
revoke all on function public.admin_upgrade_undo(uuid) from public, anon;
grant execute on function public.admin_upgrade_undo(uuid) to authenticated;

-- The batch paths are gone.
drop function if exists public.admin_upgrades_prepare(text, integer);
drop function if exists public.admin_upgrades_go_many(uuid[]);
drop function if exists public.admin_upgrade_request(text, integer, text);

-- ------------------------------------------------------ drafted upgrades

-- Drafted upgrades, loaded by a later migration:
-- [{"slug": "...", "kind": "title" | "search_description" | "description",
--   "text": "...", "note": "what it was based on", "before": "..."}].
-- A page with an owner keeps its own description. A draft replaces
-- one of the same kind that was still waiting (or had failed), unless
-- that one holds the founder's own wording; one on its way to the
-- site is left alone. A version that is live stays live until the
-- draft is approved and written over it. The page's open request is
-- closed.
create or replace function public.import_page_upgrades(p jsonb, p_batch text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e       jsonb;
  v       public.venues;
  pend    public.page_upgrades;
  live_   public.page_upgrades;
  kind_   text;
  txt     text;
  nt      text;
  bef     text;
  added   integer := 0;
  skipped jsonb := '[]'::jsonb;
  venues_ uuid[] := '{}';
begin
  if jsonb_typeof(p) <> 'array' then
    return jsonb_build_object('added', 0, 'skipped', '[]'::jsonb);
  end if;
  for e in select * from jsonb_array_elements(p) loop
    kind_ := coalesce(e ->> 'kind', '');
    txt := coalesce(e ->> 'text', '');
    nt := nullif(left(coalesce(e ->> 'note', ''), 2000), '');
    v := null;
    select * into v from public.venues x where x.webflow_slug = e ->> 'slug' limit 1;
    if v.id is null then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'why', 'no page with that address');
      continue;
    end if;
    if kind_ not in ('title', 'search_description', 'description') then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'why', 'unknown kind');
      continue;
    end if;
    if kind_ = 'description' and v.listing_owner_email is not null then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'why', 'the owner writes this page');
      continue;
    end if;
    if kind_ in ('title', 'search_description') then
      txt := regexp_replace(trim(txt), '\s+', ' ', 'g');
    end if;
    if public.upgrade_text_problem(kind_, txt) <> '' then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'kind', kind_,
                                               'why', public.upgrade_text_problem(kind_, txt));
      continue;
    end if;
    live_ := null;
    select * into live_ from public.page_upgrades u
     where u.venue_id = v.id and u.kind = kind_ and u.status = 'applied'
     limit 1;
    if live_.id is not null and txt = coalesce(live_.final_text, live_.proposed_text) then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'kind', kind_,
                                               'why', 'already live on the page');
      continue;
    end if;
    bef := coalesce(live_.final_text, nullif(e ->> 'before', ''),
                    public.upgrade_current(v, kind_));
    pend := null;
    select * into pend from public.page_upgrades u
     where u.venue_id = v.id and u.kind = kind_
       and u.status in ('proposed', 'approved', 'failed')
     limit 1 for update;
    if pend.id is not null and pend.status = 'approved' then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'kind', kind_,
                                               'why', 'a change is on its way to the page');
      continue;
    end if;
    if pend.id is not null
       and (pend.source = 'founder'
            or (pend.final_text is not null
                and pend.final_text is distinct from pend.proposed_text)) then
      skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'kind', kind_,
                                               'why', 'the founder''s own wording is waiting');
      continue;
    end if;
    if pend.id is not null then
      -- previous_value is kept: after a write that failed half way it
      -- is the only copy of what the page said before.
      update public.page_upgrades
         set status = 'proposed', proposed_text = txt, final_text = null, error = null,
             before_text = coalesce(bef, before_text), source = 'drafted',
             batch = nullif(coalesce(p_batch, e ->> 'batch', ''), ''), note = nt,
             impact = public.upgrade_impact(v, kind_), created_at = now(),
             decided_at = null, decided_by = null, writing_since = null
       where id = pend.id;
    else
      begin
        insert into public.page_upgrades (venue_id, kind, before_text, proposed_text, source,
                                          batch, note, impact)
        values (v.id, kind_, bef, txt, 'drafted',
                nullif(coalesce(p_batch, e ->> 'batch', ''), ''), nt,
                public.upgrade_impact(v, kind_));
      exception when unique_violation then
        skipped := skipped || jsonb_build_object('slug', e ->> 'slug', 'kind', kind_,
                                                 'why', 'changed while loading');
        continue;
      end;
    end if;
    added := added + 1;
    if not v.id = any(venues_) then venues_ := venues_ || v.id; end if;
  end loop;
  if added > 0 then
    update public.upgrade_requests set status = 'done', done_at = now()
     where status = 'open' and venue_id = any(venues_);
  end if;
  return jsonb_build_object('added', added, 'skipped', skipped);
end $$;
revoke all on function public.import_page_upgrades(jsonb, text) from public, anon, authenticated;
grant execute on function public.import_page_upgrades(jsonb, text) to service_role;

-- ------------------------------------------------------ the sync's side

-- The push reports back (see migrations 125 and 127). The title and
-- the page description are kept in the page facts too, so the page's
-- "now" follows a change at once. When a change lands on a part that
-- already had a live one, the older one becomes history here, and
-- not before: until then it could still be undone.
create or replace function public.upgrade_done(
  p_id uuid, p_ok boolean, p_previous text default null,
  p_error text default null, p_words integer default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  u    public.page_upgrades;
  urls text[];
begin
  select * into u from public.page_upgrades where id = p_id for update;
  if u.id is null or u.status not in ('approved', 'undo_requested') then
    return;
  end if;
  if not coalesce(p_ok, false) then
    update public.page_upgrades
       set status = case when u.status = 'undo_requested' then 'applied' else 'failed' end,
           error = left(coalesce(p_error, 'The website did not accept it.'), 400),
           writing_since = null
     where id = p_id;
    return;
  end if;
  if u.status = 'approved' then
    update public.page_upgrades
       set status = 'superseded', writing_since = null
     where venue_id = u.venue_id and kind = u.kind and id <> u.id
       and status in ('applied', 'undo_requested');
    update public.page_upgrades
       set status = 'applied', applied_at = now(), error = null, writing_since = null,
           previous_value = coalesce(previous_value, p_previous)
     where id = p_id;
    if u.kind = 'search_description' then
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('meta', u.final_text, 'meta_generic', false));
    elsif u.kind = 'title' then
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('title', u.final_text));
    elsif u.kind = 'photos' then
      urls := coalesce(public.upgrade_photo_list(u.final_text), '{}'::text[]);
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('photos', coalesce(array_length(urls, 1), 0),
                           'photo_urls', to_jsonb(urls)));
    else
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('desc_words', greatest(coalesce(p_words, 1), 1),
                           'desc', left(coalesce(u.final_text, ''), 6000)));
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
    elsif u.kind = 'title' then
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('title', coalesce(u.previous_value, '')));
    elsif u.kind = 'photos' then
      urls := coalesce(public.upgrade_photo_list(u.previous_value), '{}'::text[]);
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('photos', coalesce(array_length(urls, 1), 0),
                           'photo_urls', to_jsonb(urls)));
    else
      -- The page text as it was read before this change; when that
      -- was never read, "not known" until tonight's sync reads it.
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('desc_words', greatest(coalesce(p_words, 0), 0)));
      update public.venue_page_facts
         set facts = case when u.before_text is null then facts - 'desc'
                          else facts || jsonb_build_object('desc', left(u.before_text, 6000)) end
       where venue_id = u.venue_id;
    end if;
  end if;
end $$;
revoke all on function public.upgrade_done(uuid, boolean, text, text, integer) from public, anon, authenticated;
grant execute on function public.upgrade_done(uuid, boolean, text, text, integer) to service_role;

-- For the nightly sync report (readable on the sync-reports branch):
-- which pages have been asked for, and where the queue stands. No
-- page text.
create or replace function public.upgrades_report()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'page_requests', (select coalesce(jsonb_agg(jsonb_build_object(
                         'slug', v.webflow_slug, 'name', v.name, 'type', v.type,
                         'area', coalesce(f.facts ->> 'area', v.neighbourhood),
                         'region', f.facts ->> 'region', 'country', v.country,
                         'note', r.note, 'asked_at', r.created_at)
                         order by r.created_at), '[]'::jsonb)
                        from public.upgrade_requests r
                        join public.venues v on v.id = r.venue_id
                        left join public.venue_page_facts f on f.venue_id = v.id
                       where r.status = 'open'),
    'open_requests', '[]'::jsonb,
    'queue', (select coalesce(jsonb_object_agg(s.k, s.n), '{}'::jsonb)
                from (select kind || ':' || status as k, count(*) n
                        from public.page_upgrades group by 1) s),
    'drafted_slugs', (select coalesce(jsonb_agg(distinct v.webflow_slug), '[]'::jsonb)
                        from public.page_upgrades u join public.venues v on v.id = u.venue_id
                       where u.source = 'drafted' and u.status not in ('undone', 'superseded')))
$$;
revoke all on function public.upgrades_report() from public, anon, authenticated;
grant execute on function public.upgrades_report() to service_role;

-- ------------------------------------------------------------ the numbers

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
    'text', jsonb_build_object(
      'generic_meta', (select count(*) from public.venues v
                        where public.upgrade_page_is_live(v) and public.upgrade_meta_is_generic(v)),
      'no_desc_coworking', (select count(*) from public.venues v
                             where public.upgrade_page_is_live(v) and v.type = 'coworking'
                               and public.upgrade_facts(v.id) is not null
                               and coalesce((public.upgrade_facts(v.id) ->> 'desc_words')::int, 0) = 0),
      'no_desc_cafe', (select count(*) from public.venues v
                        where public.upgrade_page_is_live(v) and v.type <> 'coworking'
                          and public.upgrade_facts(v.id) is not null
                          and coalesce((public.upgrade_facts(v.id) ->> 'desc_words')::int, 0) = 0),
      'requested', (select count(*) from public.upgrade_requests r
                     where r.status = 'open' and r.venue_id is not null),
      'waiting', (select count(*) from public.page_upgrades u
                   where u.kind <> 'photos' and u.status = 'proposed'),
      'search_pages', (select count(distinct s.slug) from public.page_search s
                        join public.venues v on v.webflow_slug = s.slug
                       where public.upgrade_page_is_live(v)),
      'search_at', (select max(s.measured_at) from public.page_search s)),
    'kinds', jsonb_build_array(
      jsonb_build_object(
        'kind', 'photos',
        'title', 'Photos',
        'what', 'A page holds five photos. Open the place on Google, copy the image address of a photo and paste it into a free slot; the photos already on the page stay where they are.',
        'instant', false,
        'paste', true,
        'gap', (select count(*) from public.venues v
                 where public.upgrade_page_is_live(v)
                   and (public.upgrade_facts(v.id) ->> 'photos') is not null
                   and (public.upgrade_facts(v.id) ->> 'photos')::int < 5
                   and not public.upgrade_owner_photos(v)
                   and not exists (select 1 from public.page_upgrades u
                                    where u.venue_id = v.id and u.kind = 'photos'
                                      and u.status in ('approved', 'undo_requested'))),
        'gap_words', 'pages with fewer than five photos',
        'gap_more', (select count(*) from public.venues v
                      where public.upgrade_page_is_live(v)
                        and (public.upgrade_facts(v.id) ->> 'photos')::int = 1
                        and not public.upgrade_owner_photos(v)
                        and not exists (select 1 from public.page_upgrades u
                                         where u.venue_id = v.id and u.kind = 'photos'
                                           and u.status in ('approved', 'undo_requested'))),
        'gap_more_words', 'of them with a single photo',
        'waiting', (select count(*) from public.page_upgrades u
                     where u.kind = 'photos' and u.status = 'proposed'))),
    'requests', '[]'::jsonb
  ) into out;
  return out;
end $$;
revoke all on function public.admin_upgrades_overview() from public, anon;
grant execute on function public.admin_upgrades_overview() to authenticated;
