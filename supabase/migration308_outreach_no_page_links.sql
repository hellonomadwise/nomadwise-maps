-- ============================================================
-- Migration 308: a line with no page gets a clean claim link, and a
-- space with several locations gets its own email
-- ============================================================
-- Jonathan, 10 Nov 2026, on the reply to WORX: "this template could be
-- better. the claim link looks dodgy". WORX's line covers four
-- locations, so it is tied to no single page, and the email carried
-- the long nomadmaps.io/?claim=WORX%20%28... link and the whole
-- bracketed name twice, and offered to "put WORX on nomadwise.io" when
-- its four pages are already there.
--
-- 1. A line with no page is called by its short name in an email:
--    "WORX", not "WORX (Jawatte House, Havelock House, Nawala House)".
-- 2. Its claim link is nomadwise.io/claim/worx: a short link on the
--    name, which opens the claim form searched for it (and still knows
--    which email it was sent to). The long link is only the last
--    resort.
-- 3. When several live pages share the line's website, the email
--    window is told (several, suggest) and a new template, "Several
--    locations: their pages are on Nomadwise", names them: {pages},
--    {pages_count}.
-- 4. The window is also told when the email does not point at a page
--    (problem), in the words the send refusal uses.
-- ============================================================

-- "WORX (Jawatte House, ...)" -> "WORX"; "Linuxx Serviced Offices –
-- Vanissa Building" -> "Linuxx Serviced Offices".
create or replace function public.outreach_brand(p_name text)
returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(coalesce(p_name, ''), '\s*(\(| [–—|-] |: ).*$', '')), '')
$$;

-- The website's domain, or nothing for a social or link-in-bio site.
create or replace function public.outreach_own_domain(p_url text)
returns text language sql immutable as $$
  select case when public.outreach_domain(p_url) in (
           'instagram.com', 'facebook.com', 'm.facebook.com', 'linktr.ee', 'google.com',
           'maps.google.com', 'goo.gl', 'wa.me', 'bit.ly', 'sites.google.com',
           'business.site', 'linkedin.com', 'tiktok.com')
         then null else public.outreach_domain(p_url) end
$$;

-- A short claim link on a name: the code is the name as a web address
-- ("worx"), kept in claim_links with the name to search for and the
-- address it was sent to. Returns the code, or null when the name
-- gives none.
create or replace function public.claim_link_brand(p_text text, p_email text, p_channel text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  brand text := public.outreach_brand(p_text);
  code_ text;
  em    text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  ch    text := case when p_channel = 'whatsapp' then 'whatsapp' else 'email' end;
begin
  if brand is null then return null; end if;
  code_ := btrim(regexp_replace(lower(translate(brand,
             'ÁÀÂÄÃÅáàâäãåÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÖÕóòôöõÚÙÛÜúùûüÇçÑñ',
             'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')),
           '[^a-z0-9]+', '-', 'g'), '-');
  if length(code_) < 2 then return null; end if;
  insert into public.claim_links (code, slug, email, channel)
  values (code_, brand, em, ch)
  on conflict (code) do update
    set slug = excluded.slug, email = excluded.email, channel = excluded.channel;
  return code_;
end $$;

revoke all on function public.claim_link_brand(text, text, text) from public, anon, authenticated;

-- ---- the email window's preview

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  cut  integer;
begin$a$,
$a$  cut  integer;
  several text[];   -- live pages that share an unlinked line's website (migration 308)
  pages_words text;
begin$a$,
$m$share an unlinked line's website (migration 308)$m$);

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  space := coalesce(nullif(trim(c.space_name), ''), v.name, 'your space');$a$,
$a$  -- a line with no page goes by its short name (migration 308)
  space := coalesce(case when c.venue_id is null then public.outreach_brand(c.space_name) end,
                    nullif(trim(c.space_name), ''), v.name, 'your space');$a$,
$m$goes by its short name (migration 308)$m$);

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  claim_link := coalesce(claim_link, 'https://nomadmaps.io/?claim='$a$,
$a$  -- no page: a short link on the name (migration 308); the long one last
  claim_link := coalesce(claim_link,
             'https://nomadwise.io/claim/' || public.claim_link_brand(space, c.email,
               case when right(p_key, 3) = '_wa' then 'whatsapp' else 'email' end),
             'https://nomadmaps.io/?claim='$a$,
$m$a short link on the name (migration 308)$m$);

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  price := case when coalesce(v.country, c.country, '') <> ''$a$,
$a$  -- several locations: the live pages that share this line's website
  if c.venue_id is null and public.outreach_own_domain(c.website) is not null then
    select array_agg(v2.name order by v2.name) into several
      from public.venues v2
     where v2.website_status = 'released' and coalesce(v2.webflow_slug, '') <> ''
       and public.outreach_own_domain(v2.website) = public.outreach_own_domain(c.website);
    if coalesce(array_length(several, 1), 0) < 2 then several := null; end if;
  end if;
  pages_words := case
    when several is null then space
    when array_length(several, 1) > 6 then
      array_to_string(several[1:5], ', ') || ' and ' || (array_length(several, 1) - 5) || ' more'
    else array_to_string(several[1:array_length(several, 1) - 1], ', ')
         || ' and ' || several[array_length(several, 1)] end;

  price := case when coalesce(v.country, c.country, '') <> ''$a$,
$m$the live pages that share this line's website$m$);

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  subj := replace(subj, '{space}', space);$a$,
$a$  subj := replace(subj, '{space}', space);
  subj := replace(subj, '{pages_count}', coalesce(array_length(several, 1), 1)::text);$a$,
$m$subj := replace(subj, '{pages_count}'$m$);

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  body := replace(body, '{space}', space);$a$,
$a$  body := replace(body, '{space}', space);
  body := replace(body, '{pages_count}', coalesce(array_length(several, 1), 1)::text);
  body := replace(body, '{pages}', pages_words);$a$,
$m$body := replace(body, '{pages}', pages_words)$m$);

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$                            'stream', t.stream,$a$,
$a$                            'stream', t.stream,
                            -- for the window (migration 308): the pages of a line
                            -- with several locations, the template that suits it,
                            -- and why this email would be refused
                            'several', to_jsonb(several),
                            'suggest', case when several is not null and p_key in (
                                         'reply_listing', 'reply_we_know_you', 'reply_already_listed',
                                         'invite_listed', 'invite_new_page', 'follow_up')
                                       then 'reply_several' end,
                            'problem', public.outreach_body_problem(body),$a$,
$m$for the window (migration 308)$m$);

-- ---- the email for a space with several locations

insert into public.outreach_templates (key, name, subject, body, stream, sort)
values ('reply_several',
  'Several locations: their pages are on Nomadwise',
  'Your {space} pages on Nomadwise',
  E'Hi {first_name},\n\nI hope all is well with you and the team. We were in touch a while ago about {space}, and I wanted to share something we have been working on.\n\n{space} has {pages_count} pages on Nomadwise: {pages}.\n\nYou can now look after them yourself, for free, from one Owner account. Claim your first location here, then add the others from inside your account, under "Add another location":\n{claim_link}\n\nOnce they are yours, you can keep each location''s opening hours and details up to date, and add your own photos and description, whenever it suits you.\n\nIf anything is unclear, just reply to this email and I will help.\n\n{signoff}',
  'outbound', 26)
on conflict (key) do nothing;
