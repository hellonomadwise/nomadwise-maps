-- ============================================================
-- Migration 145: what the "Next up" card needs to know.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026: "I would like to get into a rhythm of opening
-- up the admin panel, and to have in front of me ... something, and
-- can make a decision on that one thing, whether it's to add photos,
-- or review something else, or decide whether to list it. I'm finding
-- it a bit tricky to look in the top right and remember the right
-- selection, there's a few too many different menu options."
--
-- The control centre now opens with one card: the next thing, why,
-- and one button that goes straight to it. People waiting on us come
-- first, then anything waiting for a Go, then the other jobs take
-- turns. The control centre already knows its own lists (claims,
-- payments, enquiries, pages to approve...). admin_next_up() tells it
-- the rest, each with how many wait and which one is first:
--   drafts     text upgrades waiting for a Go (Page upgrades)
--   prices     price changes waiting for a Go (Price check)
--   candidate  the best bet on the Candidates list
--   photos     the most promising page short of photos
--   page       the first page of "Choose a page" not dealt with yet
-- A part that cannot be read is left out; the others still come.
--
-- Nothing here writes anything.
-- ============================================================

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

  return out;
end $$;
revoke all on function public.admin_next_up() from public, anon;
grant execute on function public.admin_next_up() to authenticated;
