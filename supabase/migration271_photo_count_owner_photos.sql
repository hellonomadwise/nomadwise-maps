-- ============================================================
-- Migration 271: the photo count in the checklist matches My listing.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: Gangga Coffee Roastery Ubud showed two photos
-- in My listing but "1 of 5 added" in Performance. The checklist
-- counted the photos last read from the live page (nightly), while My
-- listing shows the owner's own photos, which replace the page's
-- photos once approved. Now the checklist counts the owner's photos
-- when there are any, and the page's photos otherwise, the same as
-- My listing.
-- ============================================================

do $$
declare d text;
begin
  select pg_get_functiondef('public.page_parts(uuid)'::regprocedure) into d;
  if position('owner_content -> ''photos''' in d) = 0 then
    d := replace(d,
      $q$jsonb_array_length(coalesce(x -> 'page_photos', '[]'::jsonb))$q$,
      $q$coalesce(nullif(jsonb_array_length(case when jsonb_typeof(v.owner_content -> 'photos') = 'array' then v.owner_content -> 'photos' else '[]'::jsonb end), 0), jsonb_array_length(coalesce(x -> 'page_photos', '[]'::jsonb)))$q$);
    if position('owner_content -> ''photos''' in d) = 0 then
      raise exception 'page_parts did not change';
    end if;
    execute d;
  end if;
end $$;
