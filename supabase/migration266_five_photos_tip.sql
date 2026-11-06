-- ============================================================
-- Migration 266: a page with fewer than five photos gets a tip.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: a space with only one photo should be told to
-- add more; the page has room for five (Gangga Coffee Roastery Ubud
-- showed one photo and four empty spaces, yet its checklist said
-- Photos done). Photos now count as done at five. With one to four,
-- the checklist and the next step say how many more to add, in the
-- Owner account and in the monthly email.
-- ============================================================

do $$
declare d text;
begin
  -- the checklist: how many photos, done at five
  select pg_get_functiondef('public.page_parts(uuid)'::regprocedure) into d;
  if position('''count''' in d) = 0 then
    d := replace(d,
      $q$jsonb_build_object('key', 'photos', 'done',
      jsonb_array_length(coalesce(x -> 'page_photos', '[]'::jsonb)) > 0),$q$,
      $q$jsonb_build_object('key', 'photos',
      'count', jsonb_array_length(coalesce(x -> 'page_photos', '[]'::jsonb)),
      'done', jsonb_array_length(coalesce(x -> 'page_photos', '[]'::jsonb)) >= 5),$q$);
    if position('''count''' in d) = 0 then
      raise exception 'page_parts did not change';
    end if;
    execute d;
  end if;

  -- the monthly email's tip
  select pg_get_functiondef('public.owner_monthly_model(uuid,date)'::regprocedure) into d;
  if position('more photo' in d) = 0 then
    d := replace(d,
      -- (the title only: the button line below it says the same and stays)
      E'                           when ''photos'' then ''Add photos''\n                           when ''description'' then ''Write your description''',
      E'                           when ''photos'' then case when coalesce((select (p ->> ''count'')::int from jsonb_array_elements(parts -> ''parts'') p where p ->> ''key'' = ''photos''), 0) between 1 and 4\n'
      || E'                             then ''Add '' || (5 - coalesce((select (p ->> ''count'')::int from jsonb_array_elements(parts -> ''parts'') p where p ->> ''key'' = ''photos''), 0)) || '' more photo'' || case when coalesce((select (p ->> ''count'')::int from jsonb_array_elements(parts -> ''parts'') p where p ->> ''key'' = ''photos''), 0) = 4 then '''' else ''s'' end\n'
      || E'                             else ''Add photos'' end\n                           when ''description'' then ''Write your description''');
    d := replace(d,
      $q$      when 'photos' then 'Photos are the first thing people look at on your page.'$q$,
      $q$      when 'photos' then case when coalesce((select (p ->> 'count')::int from jsonb_array_elements(parts -> 'parts') p where p ->> 'key' = 'photos'), 0) between 1 and 4
        then 'Your page has room for five photos and shows ' || coalesce((select (p ->> 'count')::int from jsonb_array_elements(parts -> 'parts') p where p ->> 'key' = 'photos'), 0) || '. A full gallery shows people what it is like to work there.'
        else 'Photos are the first thing people look at on your page.' end$q$);
    if position('more photo' in d) = 0 or position('room for five photos' in d) = 0 then
      raise exception 'owner_monthly_model did not change';
    end if;
    execute d;
  end if;
end $$;
