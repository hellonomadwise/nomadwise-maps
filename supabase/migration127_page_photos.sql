-- ============================================================
-- Migration 127: photos in Page upgrades.
-- (Applied automatically by the build; nothing to paste.)
--
-- 597 of the 1,011 live pages had fewer than five photos on 4 Oct
-- 2026, 378 of them a single one; nearly all are cafes. Jonathan
-- wants to fill them the way he does for a new listing: open the
-- place on Google, copy a photo's image address, paste it into a free
-- slot. So Page upgrades gets a third kind, "photos":
--   * the nightly sync records how many photos each page has and
--     their links (venue_page_facts: photos, photo_urls);
--   * admin_upgrades_photo_gaps() lists the pages short of five,
--     highest impact first;
--   * admin_upgrade_photos() saves the founder's list of links for a
--     page as an approved upgrade (saving is the Go), and the website
--     push writes them into the page's Images entry and republishes;
--   * Undo puts the earlier photos back, like any other upgrade.
-- A page can be topped up more than once: the earlier change is kept
-- as history with the new status "superseded".
-- ============================================================

alter table public.page_upgrades drop constraint if exists page_upgrades_kind_check;
alter table public.page_upgrades add constraint page_upgrades_kind_check
  check (kind in ('search_description', 'description', 'photos'));
alter table public.page_upgrades drop constraint if exists page_upgrades_status_check;
alter table public.page_upgrades add constraint page_upgrades_status_check
  check (status in ('proposed', 'approved', 'applied', 'skipped', 'failed',
                    'undo_requested', 'undone', 'superseded'));
alter table public.page_upgrades drop constraint if exists page_upgrades_source_check;
alter table public.page_upgrades add constraint page_upgrades_source_check
  check (source in ('rule', 'drafted', 'founder'));

-- Where the site's own pictures live; a link stored without it gets
-- it back (the first load of photo links is stored short).
create or replace function public.upgrade_cdn_prefix()
returns text language sql immutable as $$
  select 'https://cdn.prod.website-files.com/64b6780f84d27e4bfd91f2d6/'::text
$$;

-- A photo list as it is kept in page_upgrades: a JSON array of links.
create or replace function public.upgrade_photo_list(p text)
returns text[] language plpgsql immutable as $$
declare
  j jsonb;
begin
  begin
    j := p::jsonb;
  exception when others then
    return null;
  end;
  if jsonb_typeof(j) <> 'array' then
    return null;
  end if;
  return array(select trim(x) from jsonb_array_elements_text(j) x);
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

-- The nightly facts no longer wipe the photo count and links, which
-- arrive separately (set_page_photos).
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
    set facts = excluded.facts
                || jsonb_strip_nulls(jsonb_build_object(
                     'photos', public.venue_page_facts.facts -> 'photos',
                     'photo_urls', public.venue_page_facts.facts -> 'photo_urls')),
        updated_at = excluded.updated_at;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_page_facts(jsonb) from public, anon, authenticated;
grant execute on function public.set_page_facts(jsonb) to service_role;

-- The photos on each page: [{"cms_id": "...", "photos": ["link", ...]}]
-- or, when only the number is known, {"cms_id": "...", "n": 5}.
create or replace function public.set_page_photos(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if jsonb_typeof(p) <> 'array' then
    return 0;
  end if;
  insert into public.venue_page_facts (venue_id, facts, updated_at)
  select distinct on (v.id) v.id, x.more, now()
    from (select e ->> 'cms_id' as cms_id,
                 case when jsonb_typeof(e -> 'photos') = 'array' then
                   jsonb_build_object(
                     'photos', jsonb_array_length(e -> 'photos'),
                     'photo_urls', (select coalesce(jsonb_agg(
                                       case when u ~* '^https?://' then u
                                            else public.upgrade_cdn_prefix() || u end), '[]'::jsonb)
                                      from jsonb_array_elements_text(e -> 'photos') u))
                 else
                   jsonb_build_object('photos', greatest(coalesce((e ->> 'n')::int, 0), 0))
                 end as more
            from jsonb_array_elements(p) e
           where coalesce(e ->> 'cms_id', '') <> ''
             and (jsonb_typeof(e -> 'photos') = 'array' or (e ->> 'n') is not null)) x
    join public.venues v on v.webflow_cms_id = x.cms_id
   order by v.id
  on conflict (venue_id) do update
    set facts = public.venue_page_facts.facts || excluded.facts;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_page_photos(jsonb) from public, anon, authenticated;
grant execute on function public.set_page_photos(jsonb) to service_role;

-- A page whose owner uploaded their own photos shows those; the
-- listing sync rewrites all five slots from them, so a founder's
-- top-up would be wiped (and would wipe theirs). Such pages are left
-- to the Owner account.
create or replace function public.upgrade_owner_photos(v public.venues)
returns boolean language sql stable as $$
  select coalesce(case when jsonb_typeof(v.owner_content -> 'photos') = 'array'
                       then jsonb_array_length(v.owner_content -> 'photos') end, 0) > 0
$$;

-- The links we hold for a page's photos, in page order.
create or replace function public.upgrade_photo_urls(p_venue uuid)
returns text[] language sql stable set search_path = public as $$
  select coalesce(
    (select array(select jsonb_array_elements_text(f.facts -> 'photo_urls'))
       from public.venue_page_facts f
      where f.venue_id = p_venue and jsonb_typeof(f.facts -> 'photo_urls') = 'array'),
    '{}'::text[])
$$;

-- Pages with fewer than five photos, highest impact first; among
-- equals, the emptier page first.
create or replace function public.admin_upgrades_photo_gaps(
  p_q text default null, p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q   text := nullif(trim(coalesce(p_q, '')), '');
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
               'place_id', v.google_place_id,
               'photos', (f.facts ->> 'photos')::int,
               'urls', coalesce(f.facts -> 'photo_urls', '[]'::jsonb),
               'impact', public.upgrade_impact(v, 'photos'),
               'reason', public.upgrade_reason(v, 'photos'),
               'pending', (select u.status from public.page_upgrades u
                            where u.venue_id = v.id and u.kind = 'photos'
                              and u.status in ('proposed', 'approved', 'failed', 'undo_requested')
                            limit 1),
               -- What a change still on its way holds, so "Change"
               -- starts from that and not from the page's older list.
               'pending_urls', (select to_jsonb(public.upgrade_photo_list(
                                         coalesce(u.final_text, u.proposed_text)))
                                  from public.page_upgrades u
                                 where u.venue_id = v.id and u.kind = 'photos'
                                   and u.status in ('proposed', 'approved', 'failed')
                                 limit 1)) as row
        from public.venues v
        join public.venue_page_facts f on f.venue_id = v.id
       where public.upgrade_page_is_live(v)
         and (f.facts ->> 'photos') is not null
         and (f.facts ->> 'photos')::int < 5
         and not public.upgrade_owner_photos(v)
         and (q is null
              or v.name ilike '%' || q || '%'
              or coalesce(f.facts ->> 'area', v.neighbourhood, '') ilike '%' || q || '%'
              or coalesce(f.facts ->> 'region', '') ilike '%' || q || '%'
              or coalesce(v.country, '') ilike '%' || q || '%')
       order by public.upgrade_impact(v, 'photos') desc,
                (f.facts ->> 'photos')::int, v.name
       limit greatest(1, least(coalesce(p_limit, 60), 300))
    ) x;
  return out;
end $$;
revoke all on function public.admin_upgrades_photo_gaps(text, integer) from public, anon;
grant execute on function public.admin_upgrades_photo_gaps(text, integer) to authenticated;

-- A founder's photo list for a page, in page order. Saving is the
-- Go: the row is approved at once and the push writes it. A change
-- still waiting for this page is reworded; one already on the site
-- becomes history ("superseded") and this one takes its place.
-- p_seen is the list the founder's screen started from: when the
-- photos have changed since (the push landed, or the other founder
-- saved), the save is refused and nothing is lost.
drop function if exists public.admin_upgrade_photos(uuid, text[]);
create or replace function public.admin_upgrade_photos(
  p_venue uuid, p_urls text[], p_seen text[] default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v      public.venues;
  urls   text[];
  txt    text;
  prob   text;
  before text[];
  open_  public.page_upgrades;
  rid    uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  select * into v from public.venues where id = p_venue;
  if v.id is null or not public.upgrade_page_is_live(v) then
    raise exception 'That page is not live on the website.';
  end if;
  if public.upgrade_owner_photos(v) then
    raise exception 'This page shows its owner''s own photos; they are changed in the Owner account.';
  end if;
  urls := array(select trim(x) from unnest(coalesce(p_urls, '{}'::text[])) x where trim(x) <> '');
  txt := to_jsonb(urls)::text;
  prob := public.upgrade_text_problem('photos', txt);
  if prob <> '' then
    raise exception '%', prob;
  end if;
  before := public.upgrade_photo_urls(v.id);
  if urls = before then
    raise exception 'These are the photos already on the page.';
  end if;

  select * into open_ from public.page_upgrades u
   where u.venue_id = v.id and u.kind = 'photos'
     and u.status in ('proposed', 'approved', 'failed', 'undo_requested', 'applied')
   order by u.created_at desc limit 1 for update;
  if p_seen is not null and p_seen is distinct from
     (case when open_.status in ('proposed', 'approved', 'failed')
           then public.upgrade_photo_list(coalesce(open_.final_text, open_.proposed_text))
           else before end) then
    raise exception 'The photos for this page have changed since this list was loaded. Refresh and try again.';
  end if;
  if open_.id is not null then
    if open_.status = 'undo_requested'
       or (open_.writing_since is not null
           and open_.writing_since > now() - interval '10 minutes') then
      raise exception 'The photos for this page are being written right now. Give it a minute and try again.';
    end if;
    if open_.status in ('proposed', 'approved', 'failed') then
      update public.page_upgrades
         set status = 'approved', proposed_text = txt, final_text = txt, error = null,
             decided_at = now(), decided_by = public.upgrades_admin_email(),
             source = 'founder', writing_since = null
       where id = open_.id;
      perform public.upgrades_nudge();
      return open_.id;
    end if;
    update public.page_upgrades set status = 'superseded' where id = open_.id;
  end if;

  begin
    insert into public.page_upgrades (venue_id, kind, status, before_text, proposed_text,
                                      final_text, source, impact, decided_at, decided_by)
    values (v.id, 'photos', 'approved', to_jsonb(before)::text, txt, txt, 'founder',
            public.upgrade_impact(v, 'photos'), now(), public.upgrades_admin_email())
    returning id into rid;
  exception when unique_violation then
    raise exception 'Someone else has just changed the photos for this page. Refresh and try again.';
  end;
  perform public.upgrades_nudge();
  return rid;
end $$;
revoke all on function public.admin_upgrade_photos(uuid, text[], text[]) from public, anon;
grant execute on function public.admin_upgrade_photos(uuid, text[], text[]) to authenticated;

-- What the push should write now, with the list each change started
-- from (before_text), so the push can tell when a page's photos are
-- no longer the ones the founder saw.
create or replace function public.upgrades_to_apply(p_limit integer default 40)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.row), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'id', u.id, 'kind', u.kind, 'status', u.status,
               'final_text', u.final_text, 'previous_value', u.previous_value,
               'before_text', case when u.kind = 'photos' then u.before_text end,
               'name', v.name, 'webflow_cms_id', v.webflow_cms_id,
               'owned', v.listing_owner_email is not null,
               'owner_photos', public.upgrade_owner_photos(v)) as row
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

-- The push reports back (see migration 125). Photos keep their count
-- and links in the page facts, so the gap list follows at once.
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
       set status = 'applied', applied_at = now(), error = null, writing_since = null,
           previous_value = coalesce(previous_value, p_previous)
     where id = p_id;
    if u.kind = 'search_description' then
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('meta', u.final_text, 'meta_generic', false));
    elsif u.kind = 'photos' then
      urls := coalesce(public.upgrade_photo_list(u.final_text), '{}'::text[]);
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('photos', coalesce(array_length(urls, 1), 0),
                           'photo_urls', to_jsonb(urls)));
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
    elsif u.kind = 'photos' then
      urls := coalesce(public.upgrade_photo_list(u.previous_value), '{}'::text[]);
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('photos', coalesce(array_length(urls, 1), 0),
                           'photo_urls', to_jsonb(urls)));
    else
      perform public.upgrade_facts_merge(u.venue_id,
        jsonb_build_object('desc_words', greatest(coalesce(p_words, 0), 0)));
    end if;
  end if;
end $$;
revoke all on function public.upgrade_done(uuid, boolean, text, text, integer) from public, anon, authenticated;
grant execute on function public.upgrade_done(uuid, boolean, text, text, integer) to service_role;

-- The screen's numbers, now with the photos row.
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
                     where u.kind = 'photos' and u.status = 'proposed')),
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
