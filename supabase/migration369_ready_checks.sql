-- Migration 369: the photo part of the checklist on Ready to approve
-- cards: how many photos each page has, and which two look like the
-- same photo.
--
-- Jonathan, 28 Nov 2026: "I want to minimise the risk that a space is
-- allocated to the wrong location, or a new location is created that is
-- the incorrect name, or a space doesn't have enough photos, or a space
-- has duplicates of photos within the selected 5", then "If you're
-- confident that approve all green works, then go ahead".
--
-- Every suggested photo is already scored by an image model
-- (scripts/photo_suggest.py) and its embedding kept in photo_embeddings.
-- Two photos whose embeddings are this close (cosine 0.95 or more) are
-- the same photo or nearly: the same shot twice, a crop, a resize. On
-- 28 Nov, 5 of 142 pages waiting had such a pair among their chosen
-- photos (21 at 0.93, where it is more often two views of one room).
-- The same link twice counts too. A photo with no embedding (pasted by
-- hand from elsewhere) is only compared by its link.

create or replace function public.admin_ready_photo_checks()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  return coalesce((
    with sel as (
      select v.id as venue_id, p.uri, p.ord
        from public.venues v,
             jsonb_array_elements_text(coalesce(v.website_photos, '[]'::jsonb))
               with ordinality p(uri, ord)
       where v.website_status = 'queued'
         and v.website_approved_at is null
         and jsonb_typeof(v.website_photos) = 'array'
         and p.uri like 'http%'),
    e as (
      select s.*,
             case when pe.embedding is null then null
                  else array(select (x)::float8
                               from jsonb_array_elements_text(pe.embedding) x) end as vec
        from sel s
        left join public.photo_embeddings pe on pe.uri = s.uri),
    pairs as (
      select a.venue_id, a.ord as a_ord, b.ord as b_ord, a.uri as a_uri, b.uri as b_uri,
             case when a.uri = b.uri then 1.0
                  when a.vec is not null and b.vec is not null
                  then (select sum(x * y) from unnest(a.vec, b.vec) t(x, y))
             end as sim
        from e a join e b on a.venue_id = b.venue_id and a.ord < b.ord),
    per as (
      select s.venue_id,
             count(*) as photos,
             count(*) filter (where e2.vec is null) as unchecked
        from sel s join e e2 on e2.venue_id = s.venue_id and e2.ord = s.ord
       group by s.venue_id)
    select jsonb_object_agg(per.venue_id::text, jsonb_build_object(
             'photos', per.photos,
             'unchecked', per.unchecked,
             'dups', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'a', p.a_ord, 'b', p.b_ord,
                        'a_uri', p.a_uri, 'b_uri', p.b_uri,
                        'sim', round(p.sim::numeric, 3)) order by p.sim desc)
                 from pairs p
                where p.venue_id = per.venue_id and p.sim >= 0.95), '[]'::jsonb)))
      from per), '{}'::jsonb);
end $$;
revoke all on function public.admin_ready_photo_checks() from public, anon;
grant execute on function public.admin_ready_photo_checks() to authenticated;
