-- Migration 336: put 47 London coworking and office operators in the
-- queue, with names checked against each operator's own website
-- (Jonathan asked for this on 21 Nov 2026; WeWork included).
--
-- These are places already found on the map (discovered_places) that
-- were never made into spaces. This does what the Yes button in
-- Candidates does (candidate_queue), once, for a fixed list, with two
-- differences: the name is the checked one below, and the type is
-- always coworking. Each one still becomes a page the usual way.
-- Safe to run twice: a place that is already a space is left alone.
do $$
declare
  r    record;
  d    public.discovered_places%rowtype;
  near record;
  v_id uuid;
begin
  for r in
    select * from (values
  ('ChIJH5p8i1AbdkgRD01IW5aTTS4', 'WeWork Kings Place'),
  ('ChIJl2xsELgEdkgR4DI-EZp299s', 'WeWork 10 York Road'),
  ('ChIJ965gFbUEdkgRdDo6c8CnHaU', 'WeWork Aldwych House'),
  ('ChIJ_WpGcqcbdkgRjFAvoaxK2wk', 'WeWork Aviation House'),
  ('ChIJhcWby0cFdkgR4iXZq-LEqQA', 'WeWork 123 Buckingham Palace Road'),
  ('ChIJ-7zUdc8FdkgRgntV2Jcozhc', 'Flex by Grosvenor - 22 Grosvenor Gardens'),
  ('ChIJ0U73FbkFdkgR7IMDCoQYCTk', 'Flex by Grosvenor - 25 Eccleston Place'),
  ('ChIJdQ98njmr2EcR0ND7k6FCtzw', 'Clockwise Bromley'),
  ('ChIJ7cOc8igbdkgR0X4ZOi9hNCE', 'Clockwise Wood Green'),
  ('ChIJ0Q35BB8FdkgR7Ngw2X2AFDU', 'Cubo Soho'),
  ('ChIJ21gyzpAcdkgRfYgad-qR6-A', 'De Beauvoir Block'),
  ('ChIJpdOf7mkbdkgR9bSXMP0RlxI', 'Elementa - Wogan House'),
  ('ChIJOfGsRw6o2EcR2bzSEgqt9QQ', 'Expressway by General People'),
  ('ChIJARScYEQDdkgRSqd1HfsKwfs', 'GO Bermondsey'),
  ('ChIJE8ZbCZ8DdkgR0nmX3SMDPj8', 'Halkin - 68 King William Street'),
  ('ChIJue1nFgsDdkgRixh-NW5uhdk', 'Huckletree Leadenhall'),
  ('ChIJ9Q-VWjQddkgRLFBuxc3atTU', 'Huckletree Liverpool Street'),
  ('ChIJW84v7c8FdkgRV3FayiDTjWM', 'Huckletree Soho'),
  ('ChIJOzc5wH8FdkgRrlIGRShFmQI', 'Huckletree Westminster'),
  ('ChIJ60ieVPQbdkgRMw-NpYY85_E', 'Industrious 15 Fitzroy'),
  ('ChIJ492AKk4bdkgRyJtlT1r8lUo', 'Knotel Old Sessions House'),
  ('ChIJcTUjesoEdkgRO43LHgGCAhg', 'Makerversity'),
  ('ChIJb24lfgYbdkgRZEVpRM8zFzM', 'MYO King''s Cross'),
  ('ChIJETBJPiUbdkgRqRXjuurmnrM', 'Regus Euston - Woburn Place'),
  ('ChIJ_eMV0SIFdkgRPz_Tzca1mls', 'RIVVIA Covent Garden'),
  ('ChIJayAT5ykbdkgRbtdXa9LWytc', 'Runway East Bloomsbury'),
  ('ChIJY2Q_HKYcdkgRGi4XEXka1mw', 'Runway East Shoreditch'),
  ('ChIJ6TbG5Eip2EcRo8n88ZaQHQ0', 'Silver Building'),
  ('ChIJt-kgiwEbdkgR-8HAHPvFBcc', 'Spaces Highbury and Islington'),
  ('ChIJ5zlj3BwbdkgRUW-Zwl7UnDQ', 'Spaces Finsbury Park'),
  ('ChIJ52SZ8OwbdkgRClt1l57uSUA', 'Spaces Angel Islington'),
  ('ChIJI5JFkDYFdkgRjVFK28OLtKM', 'Spaces Covent Garden'),
  ('ChIJp83PU-AbdkgRbENt3s2GJNw', 'Spaces Euston Road'),
  ('ChIJFRJZ1dUadkgRt0vcQIBo3dw', 'Spaces Fitzrovia'),
  ('ChIJy2utjicbdkgRaJylK7EsyCo', 'Spaces Theobalds Road'),
  ('ChIJ0a6ce-0FdkgRfA2iVkdj-HM', 'Spaces Victoria'),
  ('ChIJ0eWN5QIbdkgRM8JJZ5axKMU', 'Techspace Goswell Road'),
  ('ChIJP4JAoEMbdkgRzX-dlTNagyc', 'Techspace St Andrew Street'),
  ('ChIJkTQYfIUFdkgRdr5VCZCnFfg', 'The Engine Room'),
  ('ChIJr56xlL0DdkgR4jl3XXu4PcY', 'The Work Project - One Leadenhall'),
  ('ChIJgwNbmE0LdkgR2E3MHclK9Xo', 'TownSq Kingston'),
  ('ChIJiawHRbIFdkgRN4qDA3r0NLw', 'x+why Arding & Hobbs'),
  ('ChIJ6euOd5EbdkgR-ZhZuSBEAAs', 'x+why Bloomsbury House'),
  ('ChIJJes_T9sFdkgRY7gOCpaZ9Bo', 'x+why Fivefields'),
  ('ChIJu9m2zXcFdkgR4GEMmmAYUUY', 'x+why One Great Cumberland Place'),
  ('ChIJAaXptJMPdkgROtC_CQWHUOk', 'ARC Earlsfield'),
  ('ChIJo9t0XrQJdkgR7JbKxk_h_44', 'Oru Space Sutton')
    ) as t(place, name)
  loop
    select * into d from public.discovered_places
     where google_place_id = r.place;
    if not found then continue; end if;
    if exists (select 1 from public.venues
                where google_place_id = r.place) then
      continue;
    end if;

    select * into near from public.candidate_region(d.lat, d.lng);

    insert into public.venues (
      name, type, city, country, google_place_id, lat, lng,
      google_rating_snapshot, google_reviews_snapshot,
      status, website_status, source)
    values (
      r.name, 'coworking',
      coalesce(near.region_name, 'London'),
      coalesce(near.region_country, 'England'),
      d.google_place_id, d.lat, d.lng,
      d.rating, d.user_rating_count,
      'verified', 'queued', 'candidate')
    returning id into v_id;

    insert into public.candidate_decisions
      (google_place_id, decision, name, venue_id)
    values (d.google_place_id, 'queued', r.name, v_id)
    on conflict (google_place_id) do update
       set decision = 'queued',
           name = excluded.name,
           venue_id = excluded.venue_id,
           reason = null,
           note = null,
           decided_by = null,
           decided_at = now();
  end loop;
end $$;
