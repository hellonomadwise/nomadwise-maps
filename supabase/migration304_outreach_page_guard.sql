-- ============================================================
-- Migration 304: an outreach email always points at the space's page
-- ============================================================
-- Jonathan, 10 Nov 2026, on the email to Stone Soup: "This looks
-- wrong". Its old email line (Olga, 2024) was never tied to the space's
-- page, so the email said "has a page on nomadwise.io: nomadwise.io"
-- (the home page) and its button went to the long nomadmaps.io search
-- link. The note in the email box (migration 296's app change) was not
-- enough to stop it.
--
-- 1. outreach_autolink(contact): a line with no page is tied to its
--    page by itself when exactly one live page shares its website's
--    domain (social and link-in-bio sites left out). If that page
--    already has its own line, the two are joined (every message kept,
--    the other address noted). Run when an email is opened.
-- 2. Sending refuses an email that still carries the long search link
--    or the bare home page as "your page", with a plain reason: tie the
--    line to its page first, or pick a template without page links.
-- (Eight such lines were joined by hand the same day: Stone Soup, ecos
-- Hannover-Süd, Setter Ubud, The Work Loft Silom, myOffice Dubai Marina
-- Plaza, ViOS Autograph, Uncommon Borough.)
-- ============================================================

create or replace function public.outreach_domain(p_url text)
returns text language sql immutable as $$
  select nullif(split_part(regexp_replace(lower(btrim(coalesce(p_url, ''))),
                                          '^(https?://)?(www\.)?', ''), '/', 1), '')
$$;

create or replace function public.outreach_autolink(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c    public.space_contacts%rowtype;
  dom  text;
  vid  uuid;
  n    integer;
  other uuid;
begin
  select * into c from public.space_contacts where id = p_id;
  if not found or c.venue_id is not null or c.is_test then
    return c.venue_id;
  end if;
  dom := public.outreach_domain(c.website);
  if dom is null or dom in ('instagram.com', 'facebook.com', 'm.facebook.com', 'linktr.ee',
                            'google.com', 'maps.google.com', 'goo.gl', 'wa.me', 'bit.ly',
                            'sites.google.com', 'business.site', 'linkedin.com', 'tiktok.com') then
    return null;
  end if;
  select count(*), min(v.id::text)::uuid into n, vid
    from public.venues v
   where v.website_status = 'released' and coalesce(v.webflow_slug, '') <> ''
     and public.outreach_domain(v.website) = dom;
  if n <> 1 then
    return null;
  end if;
  select id into other from public.space_contacts
   where venue_id = vid and not is_test and id <> p_id
   order by created_at limit 1;
  if other is not null then
    perform public.outreach_merge(p_id, other);
  else
    update public.space_contacts set venue_id = vid, updated_at = now() where id = p_id;
  end if;
  return vid;
end $$;

revoke all on function public.outreach_autolink(uuid) from public, anon, authenticated;

-- opening an email ties the line to its page first
select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id;$a$,
$a$  if not public.is_admin() then raise exception 'admin only'; end if;
  -- a line with no page is tied to its page first (migration 304)
  perform public.outreach_autolink(p_id);
  select * into c from public.space_contacts where id = p_id;$a$,
$m$tied to its page first (migration 304)$m$);

-- the plain words of the refusal, shared by both ways of sending
create or replace function public.outreach_body_problem(p_body text)
returns text language sql immutable as $$
  select case
    when coalesce(p_body, '') ~ 'https://nomadmaps\.io/\?claim='
      or coalesce(p_body, '') ~ 'nomadwise\.io:\s*https://www\.nomadwise\.io/?\s*(\n|$)'
    then 'This email does not point at the space''s own page (it has the long claim '
         || 'search link or the nomadwise.io home page). Tie the line to its page '
         || 'first (Remove... > Already in touch on another line), or pick a '
         || 'template without page links.'
  end
$$;

select public.pm_patch_fn('public.admin_outreach_send(uuid,text,text,text,boolean)',
$a$  if not found then raise exception 'Contact not found.'; end if;
  if c.email is null then raise exception 'This contact has no email address.'; end if;$a$,
$a$  if not found then raise exception 'Contact not found.'; end if;
  if c.email is null then raise exception 'This contact has no email address.'; end if;
  -- never an email that points nowhere (migration 304)
  if public.outreach_body_problem(p_body) is not null then
    raise exception '%', public.outreach_body_problem(p_body);
  end if;$a$,
$m$never an email that points nowhere (migration 304)$m$);

select public.pm_patch_fn('public.admin_outreach_log_sent(uuid,text,text,text,boolean)',
$a$  if not found then raise exception 'Contact not found.'; end if;
  if c.unsubscribed_at is not null then$a$,
$a$  if not found then raise exception 'Contact not found.'; end if;
  -- never an email that points nowhere (migration 304)
  if public.outreach_body_problem(p_body) is not null then
    raise exception '%', public.outreach_body_problem(p_body);
  end if;
  if c.unsubscribed_at is not null then$a$,
$m$never an email that points nowhere (migration 304)$m$);
