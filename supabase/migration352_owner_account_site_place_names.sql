-- Migration 352: the Owner account names a space's place as
-- nomadwise.io does, not as Google files it (Jonathan, 24 Nov 2026, on
-- Working on Air: "where it says Lombok, this I think is misleading ...
-- this should say 'Gili Air, Gili Islands' if anything. or just Gili
-- Air"). Google's city for Gili Air is "Kabupaten Lombok Utara", the
-- regency; the site's own region is "Gili Islands".
--
-- owner_venues() and admin_owner_view() each send two more fields with
-- a space: site_location and site_region, the names of its location and
-- region pages on nomadwise.io (null where it has none). Nothing else
-- they return changes. The screen uses them in place of Google's
-- neighbourhood and city where they exist.

select public.pm_patch_fn('public.owner_venues()',
  $a$      'neighbourhood', v.neighbourhood,$a$,
  $a$      'neighbourhood', v.neighbourhood,
      'site_location', (select lo.name from public.webflow_locations lo where lo.id = v.webflow_location_id),
      'site_region', (select r.name from public.webflow_regions r where r.id = v.webflow_region_id),$a$,
  $a$'site_region'$a$);

select public.pm_patch_fn('public.admin_owner_view(text)',
  $a$      'neighbourhood', v.neighbourhood,$a$,
  $a$      'neighbourhood', v.neighbourhood,
      'site_location', (select lo.name from public.webflow_locations lo where lo.id = v.webflow_location_id),
      'site_region', (select r.name from public.webflow_regions r where r.id = v.webflow_region_id),$a$,
  $a$'site_region'$a$);
