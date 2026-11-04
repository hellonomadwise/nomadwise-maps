-- ============================================================
-- Migration 247: every designed email in Nomadwise red, with the logo.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 4 Nov 2026: "for any of the transactional emails, make
-- sure that it never has the ... orange ... It has to be the nomadwise
-- red color. And it should be the nomadwise logo and nomadwise
-- branding. And also ... border radius 8".
--
-- email_html (every designed email: owner, claim, enquiry, nomad
-- confirmation) and email_md_links used #E0442E, an orange red, for the
-- buttons, links, signature and the "nomadwise" word at the top. All of
-- it is now Nomadwise red #FF444F, and the top shows the real logo
-- (palm-tree circle and "nomadwise.io", the same as the website header),
-- served from https://nomadmaps.io/email/nomadwise-logo.png (app/web/email,
-- 600x178, shown at 150x44). If an inbox blocks images it says
-- "nomadwise.io". Corners were already 8px (migration 246).
-- ============================================================

do $$
declare
  d text;
begin
  select pg_get_functiondef('public.email_html(text, text, text, boolean)'::regprocedure) into d;
  d := replace(d,
    '<span style="font-size:22px;font-weight:800;color:#E0442E;letter-spacing:-0.3px;">nomadwise</span>',
    '<img src="https://nomadmaps.io/email/nomadwise-logo.png" width="150" height="44" alt="nomadwise.io" style="display:inline-block;vertical-align:middle;border:0;outline:none;text-decoration:none;width:150px;height:44px;color:#FF444F;font-size:20px;font-weight:800;">');
  d := replace(d,
    'letter-spacing:1.2px;margin-left:4px;">FOR SPACES',
    'letter-spacing:1.2px;margin-left:6px;vertical-align:middle;">FOR SPACES');
  d := replace(d, '#E0442E', '#FF444F');
  if position('nomadwise-logo.png' in d) = 0 or position('#E0442E' in d) > 0 then
    raise exception 'email_html: header or colour not found';
  end if;
  execute d;

  select pg_get_functiondef('public.email_md_links(text)'::regprocedure) into d;
  d := replace(d, '#E0442E', '#FF444F');
  execute d;
end $$;
