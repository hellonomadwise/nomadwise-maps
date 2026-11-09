-- ============================================================
-- Migration 293: claim links on nomadwise.io, without a code
-- ============================================================
-- Jonathan, 9 Nov 2026, on "Claiming the page is free:
-- https://nomadmaps.io/c/zest-ubud-7cvm": "it looks dodgy that the
-- link has 7cvm on the end. it looks fake". Links now read
--
--   https://nomadwise.io/claim/zest-ubud
--
-- the space's own page name on our own address. One redirect on the
-- website (Webflow, 301 redirects, added by Jonathan on 9 Nov):
-- /claim/(.*) to https://nomadmaps.io/c/%1, which opens the claim form
-- (c.js, migration 287).
--
-- Without the code, the link still fills in the address we wrote to
-- and still counts as an answer to our message: Outreach keeps noting
-- the address and the way (email or WhatsApp) each time it writes a
-- link (claim_links, as before), and a link that is a space's page
-- name is answered with the latest of those for that space. Links
-- already sent, with their code, keep working.
-- ============================================================

-- The link Outreach writes: the space's page name, after noting who it
-- went to and how.
create or replace function public.claim_link_plain(p_slug text, p_email text, p_channel text)
returns text language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.claim_link_code(p_slug, p_email, p_channel);
  return p_slug;
end $$;
revoke all on function public.claim_link_plain(text, text, text) from public, anon, authenticated;

-- First the nomadwise.io address (with the code), then without it.
select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$'https://nomadmaps.io/c/' || public.claim_link_code($a$,
$a$'https://nomadwise.io/claim/' || public.claim_link_code($a$,
$m$nomadwise.io/claim/$m$);
select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$'https://nomadwise.io/claim/' || public.claim_link_code($a$,
$a$'https://nomadwise.io/claim/' || public.claim_link_plain($a$,
$m$claim_link_plain$m$);

-- Opening a link: by its code as before; else, when it is a space's
-- page name, as the latest link we wrote for that space.
create or replace function public.claim_link_open(p_code text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  c text := lower(btrim(coalesce(p_code, '')));
  l public.claim_links%rowtype;
begin
  update public.claim_links set opens = opens + 1, opened_at = coalesce(opened_at, now())
   where code = c
  returning * into l;
  if found then
    return jsonb_build_object('slug', l.slug, 'email', l.email, 'from', l.channel);
  end if;
  if not exists (select 1 from public.venues v where lower(v.webflow_slug) = c) then
    return null;
  end if;
  update public.claim_links set opens = opens + 1, opened_at = coalesce(opened_at, now())
   where code = (select x.code from public.claim_links x
                  where x.slug = c order by x.created_at desc limit 1)
  returning * into l;
  if found then
    return jsonb_build_object('slug', l.slug, 'email', l.email, 'from', l.channel);
  end if;
  return jsonb_build_object('slug', c, 'email', null, 'from', 'email');
end $$;
revoke all on function public.claim_link_open(text) from public;
grant execute on function public.claim_link_open(text) to anon, authenticated;
